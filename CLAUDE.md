# mob_push — Agent Instructions

## What this library does

`mob_push` is a server-side Elixir library for sending push notifications to Mob apps.
It wraps APNs HTTP/2 (iOS) and FCM HTTP v1 (Android). It does not store tokens —
that's left to the application.

## Key files

- `lib/mob_push.ex` — public API: `send/3`, `send!/3`
- `lib/mob_push/apns.ex` — APNs adapter: ES256 JWT signing, HTTP/2 to Apple
- `lib/mob_push/fcm.ex` — FCM adapter: RS256 service account JWT → OAuth2 token → FCM
- `lib/mob_push/token_cache.ex` — ETS GenServer: caches APNs JWT + FCM OAuth2 token
- `lib/mob_push/application.ex` — starts Finch (HTTP/2 pools for Apple) + TokenCache
- `lib/mix/tasks/mob_push.install.ex` — interactive onboarding task

## Pre-release checklist

Before bumping the version and publishing, run **all** of these in order and
fix every issue — do not ship with any failures or credo warnings:

```bash
mix test                   # all 17 tests must pass
mix format                 # apply Elixir formatting
mix credo --strict         # zero issues required — fix everything, no exceptions
```

## Running tests

```bash
mix test
```

All tests are pure unit tests — no network calls, no credentials needed.

## Adding tests

Tests live in `test/mob_push/`. Every module has a corresponding test file.
No integration tests yet (would need Bypass + real credentials).

For APNs JWT tests, generate an EC key with:
```elixir
jwk = JOSE.JWK.generate_key({:ec, "P-256"})
{_, pem} = JOSE.JWK.to_pem(jwk)
```
Do NOT use `:public_key.generate_key/1` — it has OTP-version quirks with EC keys.
Do NOT use `{:namedCurve, :prime256v1}` — use the OID tuple `{1, 2, 840, 10045, 3, 1, 7}`.

The test file for `apns.ex` contains a private `build_aps/1` helper that mirrors
the private function in the module. When you add new fields to `build_aps/1` in
`apns.ex`, update the mirror in the test file too.

## Token cache behaviour

- APNs JWTs: cached 50 minutes (Apple allows up to 1 hour)
- FCM OAuth2 tokens: cached ~55 minutes (expire after 1 hour; 5-minute margin)
- Cache key for APNs: `{:apns_jwt, key_id}`
- Cache key for FCM: `{:fcm_token, client_email}`
- On 401/403: caller evicts the cache key and returns `{:error, :auth_failed}`
- Eviction is manual: `MobPush.TokenCache.evict(key)`

## Error handling conventions

- Adapters return `{:error, reason}` — never raise (except `send!/3`)
- Config errors (missing key file, etc.) return `{:error, :missing_apns_key_config}`
  rather than raising — this is intentional, keeps crashes out of the token cache GenServer
- Unexpected HTTP status returns `{:error, {:unexpected_status, status, body}}`

## Finch / HTTP/2

APNs requires HTTP/2. `MobPush.Application` pre-configures Finch pools:
```elixir
"https://api.push.apple.com"         => [protocols: [:http2], count: 2, size: 10]
"https://api.sandbox.push.apple.com" => [protocols: [:http2], count: 2, size: 10]
```
FCM uses HTTP/1.1 (Finch default). All HTTP goes through `MobPush.Finch`.

## Config structure

```elixir
config :mob_push, :apns,
  key_id:    "XXXXXXXXXX",          # 10-char Key ID
  team_id:   "XXXXXXXXXX",          # 10-char Team ID
  bundle_id: "com.example.myapp",
  key_file:  "/path/to/AuthKey.p8", # OR key_pem: "..."
  env:       :sandbox               # or :production

config :mob_push, :fcm,
  project_id:          "my-firebase-project",
  service_account_key: "/path/to/sa.json"   # OR service_account_json: %{...}
```

## Payload options

### iOS (APNs) — `build_aps/1` in `apns.ex`

| Key | Type | Notes |
|-----|------|-------|
| `:title` | string | Required |
| `:body` | string | Required |
| `:subtitle` | string | Second line under title in the tray |
| `:badge` | integer | App icon badge count; 0 to clear |
| `:sound` | string | `"default"` or bundled filename (no extension) |
| `:content_available` | boolean | Silent push — maps to `"content-available": 1` |
| `:data` | map | Merged into the APNs root (outside `aps`); values preserved as-is |

### Android (FCM) — `build_message/2` in `fcm.ex`

| Key | Type | Notes |
|-----|------|-------|
| `:title` | string | Required — goes into `notification.title` |
| `:body` | string | Required — goes into `notification.body` |
| `:data` | map | Key-value pairs; keys and values coerced to strings. Always includes `mob_notification_json`. |
| `:android` | map | Forwarded verbatim as FCM `AndroidConfig` (appearance, priority, channel, etc.) |

## mob_notification_json — the delivery mechanism

FCM sends two parallel payloads:
1. `notification` object — OS uses this to display the system notification when the app is killed/backgrounded
2. `data` object — always delivered to the app; includes `mob_notification_json`

`mob_notification_json` is a JSON-encoded map of `{title, body, source: "push", data}`. It
ensures the BEAM gets the notification payload regardless of which delivery path Android used:

- **Killed → tapped**: `MainActivity.onCreate` reads it from `intent.extras`, stores it, delivers after BEAM boots
- **Background → tapped**: `MainActivity.onNewIntent` reads it, calls `nativeDeliverNotification` directly to BEAM
- **Foreground**: `MobFirebaseService.onMessageReceived` reads it from FCM data payload, delivers to BEAM

All three paths deliver `{:notification, notif}` to the screen process.

## Android notification appearance (`:android` key)

The `:android` key passes through as FCM `AndroidConfig`. Useful fields:

```elixir
android: %{
  "notification" => %{
    "icon"       => "ic_notification",  # drawable resource name — must be white/transparent PNG
    "color"      => "#FF6200EE",        # accent color (#RRGGBB or #AARRGGBB)
    "sound"      => "default",          # or res/raw/ filename (no extension)
    "channel_id" => "messages",         # required on Android 8+; create in MainActivity.onCreate
    "image"      => "https://...",      # BigPictureStyle (HTTPS URL)
    "tag"        => "thread-42"         # collapses: same tag replaces previous notification
  },
  "priority" => "high"   # "high" = wakes screen; "normal" = quiet
}
```

Notification channels must be created by the Android app (Kotlin) before a notification
using that `channel_id` arrives. Sending to a non-existent channel silently drops the
notification on Android 8+.

## iOS notification appearance

iOS fields supported in `build_aps/1`:
- `:subtitle` — second line in the tray
- `:badge` — icon badge count
- `:sound` — `"default"` or bundled `.aiff`/`.wav`/`.caf` filename

Images on iOS require a Notification Service Extension (NSE) — an Xcode build target
the library doesn't touch. Include an image URL in `:data` and have the NSE download
and attach it.

## The install task

`mix mob_push.install` (plain Mix.Task, not Igniter — matches mob_dev style):
- Interactively prompts for APNs and FCM credentials
- Writes config stubs to `config/runtime.exs` with `System.get_env` wrappers
- Offers "skip" for each platform (inserts placeholder values)
- Explains where to get each credential as it prompts
- Options: `--ios-only`, `--android-only`, `--skip-all`

## Dependencies

- `req ~> 0.5` — HTTP client (Finch-backed, HTTP/2 support for APNs)
- `jose ~> 1.11` — JWT signing (ES256 for APNs, RS256 for FCM service account)
- `jason ~> 1.4` — JSON encode/decode
- `ex_doc` — docs only, dev runtime: false

## Generating docs

```bash
mix docs
```

Docs are output to `doc/`. The main page is `README.md`. Module groups:
- **API**: `MobPush`
- **Internals**: `MobPush.APNS`, `MobPush.FCM`, `MobPush.TokenCache`
- **Mix Tasks**: `Mix.Tasks.MobPush.Install`

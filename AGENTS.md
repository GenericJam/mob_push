# mob_push — Agent Instructions

You're in **mob_push**, a **server-side** Elixir library for sending push notifications to Mob apps. Wraps APNs HTTP/2 (iOS) + FCM v1 (Android). Zero device code. **Zero mob dependency** — it can be used with any push token from any client, mob or otherwise.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view — mob's three-repo topology and the cross-cutting pre-empt-failure rules. This file is mob_push-specific.

> **Keep this file current.** When you change payload builders, error handling, or the setup task's UX, fix it here in the same commit — not in a follow-up.

## What mob_push is, in one paragraph

Thin HTTP/2 client for Apple + Google's push endpoints. `MobPush.send(token, :ios | :android, payload_map)` returns `:ok` or `{:error, reason}`. On iOS it signs an ES256 JWT with the developer's `.p8` auth key and hits `api.push.apple.com` (or the sandbox variant); on Android it exchanges an RS256 JWT for a Google OAuth2 access token then hits FCM HTTP v1. Token storage and fan-out are out of scope — bring your own DB. Silent pushes (`content_available: true` with no visible fields) route the same way but produce data-only wire payloads that pair with `mob_wake` on the device.

## What mob_push is NOT

* **Not `mob_notify`.** `mob_notify` is the DEVICE side — schedule, cancel, register-for-push. Two ends of the same wire. Both are needed for a full remote-push flow. The wire contract is pinned by `test/fixtures/push_contract.exs`, vendored byte-identically in both repos.
* **Not `mob_wake`.** `mob_wake` is the DEVICE-side receive for silent pushes and OS scheduler firings. `mob_push` can send a payload shaped for `mob_wake` — see `MobWake.wake_payload/2` — but the receive-side handler dispatch belongs there, not here.
* **Not a token store.** `mob_push` never persists tokens. Deleted / expired tokens surface as `{:error, :device_token_expired | :device_token_not_found}`; callers are expected to prune their own DB.
* **Not a fan-out engine.** Sending to N devices means N calls. Rate limiting, retry, and backoff live in your calling code. The one exception is `MobPush.HTTP`'s brief retry of errors where the server provably did not process the request (MOB-318). Finch pool sizing is tuned for reasonable concurrency but not tens of thousands.

## Anatomy of the library

* `lib/mob_push.ex` — public `MobPush.send/3` and `send!/3`. Payload docs table lives here.
* `lib/mob_push/apns.ex` — APNs adapter: ES256 JWT signing, HTTP/2 to Apple. `build_aps/1` builds the `aps` dict. `parse_error/1` maps Apple's response codes to Elixir atoms.
* `lib/mob_push/fcm.ex` — FCM adapter: RS256 JWT → Google OAuth2 access token → FCM HTTP v1. `build_message/2` handles both visible (with `notification` block) and silent (data-only) shapes.
* `lib/mob_push/token_cache.ex` — ETS GenServer: caches the APNs JWT (~50 min) and FCM OAuth2 tokens (~55 min). Eviction is manual (`MobPush.TokenCache.evict/1`) on 401/403.
* `lib/mob_push/http.ex` — the only place APNs/FCM make HTTP requests. Retries errors where the server did not process the request (`pool_not_available` / `disconnected`: never left the node; `read_only`: the connection stopped taking writes before the request was fully written; `unprocessed` / `{:server_closed_request, :refused_stream}`: GOAWAY or REFUSED_STREAM). No retry starts later than 1.5 s after the first attempt, so a caller waits at most that plus one attempt. Never retries anything Apple/Google may have processed, because a resend could deliver the push twice.
* `lib/mob_push/application.ex` — starts Finch (pre-configured HTTP/2 pools for both Apple endpoints) + TokenCache.
* `lib/mix/tasks/mob_push.install.ex` — interactive onboarding.
* `lib/mix/tasks/mob_push.setup.apns.ex` — walks a user through creating an APNs Auth Key on Apple Developer Portal + drops the config into runtime.exs.
* `lib/mix/tasks/mob_push.setup.fcm.ex` — analogous for FCM service accounts.
* `test/fixtures/push_contract.exs` — shared with mob_notify. Change here, change there.

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

## Cross-repo work

**mob_notify:** the wire contract. Any change to the `{:push_token, ...}` shape, or the wake payload shape, must land in both repos' `test/fixtures/push_contract.exs` in the same session.

**mob_wake:** the identifier scheme. `MobWake.wake_payload/2` on the device side builds a payload map that mob_push then transports. Silent detection in `MobPush.FCM.build_message/2` (`content_available: true` AND no title/body/subtitle/sound/badge) is the switch that turns a regular push into a mob_wake-shaped one.

**Host apps:** `runtime.exs` is where credentials land. Prefer env-var opt-in (`APNS_KEY_FILE`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_ENV`, `FCM_SERVICE_ACCOUNT_KEY`, `FCM_PROJECT_ID`); config that unconditionally reads secrets breaks tests and CI.

## Testing

```bash
mix deps.get
mix test
```

All tests are pure unit tests — no network calls, no credentials needed. Tests live in `test/mob_push/`; every module has a corresponding test file. No integration tests yet — Bypass + real credentials would be needed; not currently wired.

**When adding tests for APNs JWTs**, generate the EC key with:

```elixir
jwk = JOSE.JWK.generate_key({:ec, "P-256"})
{_, pem} = JOSE.JWK.to_pem(jwk)
```

Do NOT use `:public_key.generate_key/1` — it has OTP-version quirks with EC keys. Do NOT use `{:namedCurve, :prime256v1}` — use the OID tuple `{1, 2, 840, 10045, 3, 1, 7}`.

The test file for `apns.ex` (`apns_test.exs`) contains a private `build_aps/1` helper that mirrors the private function in the module. When you add new fields to `build_aps/1` in `apns.ex`, update the mirror in the test file too.

## The pre-empt-failure rules that matter here

1. **APNs sandbox vs production is a namespace split, not a config option.** A token minted for `aps-environment=development` (Xcode debug build) works ONLY with `api.sandbox.push.apple.com`. Send it to production and you get `BadDeviceToken`. `config :mob_push, :apns, env: :sandbox` for dev-signed builds, `:production` for TestFlight / App Store. There is no dual-env mode in one config today; add it explicitly if a server needs both simultaneously.
2. **The `.p8` file is downloaded exactly once.** Apple's portal makes you download the auth key at creation; you cannot re-download it. `~/.mob/keys/` is a reasonable local location — copy to the server machine, `chmod 600`. Losing all copies means revoking + creating a new key.
3. **FCM `firebase-messaging` gradle plugin + `google-services.json` are host-level.** Plugin manifests can't contribute buildscript classpath entries — the mob_notify plugin declares these as `host_requirements` and mob_new's template ships them. If mob_push starts refusing sends with an FCM auth error, first check the host has both.
4. **Silent detection in `build_message/2` is order-sensitive.** `content_available: true` PLUS the absence of title/body/subtitle/sound/badge switches FCM to data-only mode (MOB-96) and APNs to `push_type: background` (MOB-84). Adding a visible field flips the wire back to a normal notification — sometimes that's what a caller wants (hybrid visible+silent) and sometimes it's a bug. The current tests cover both; keep them passing.
5. **APNs error strings map to atoms in `parse_error/1`** — keep it exhaustive. Apple has added new error codes over the years and a missing case falls through to `{:apns_error, "unknown"}` which is unhelpful.

## Pre-commit + pre-release checklist

Before committing — and before bumping the version and publishing — run **all** of these in order and fix every issue. Do not ship with any failures or credo warnings:

```bash
mix format                         # apply Elixir formatting
mix credo --strict                 # zero issues required — fix everything, no exceptions
mix compile --warnings-as-errors
mix test                           # every test must pass
```

## Release flow

Same release trigger model as the rest of the mob ecosystem — `mix.exs` version bump on master triggers Hex publish via `.github/workflows/release.yml`. Do not bump versions without explicit permission. See `~/code/mob/RELEASE.md`.

## Generating docs

```bash
mix docs
```

Docs are output to `doc/`. The main page is `README.md`. Module groups:
- **API**: `MobPush`
- **Internals**: `MobPush.APNS`, `MobPush.FCM`, `MobPush.TokenCache`
- **Mix Tasks**: `Mix.Tasks.MobPush.Install`

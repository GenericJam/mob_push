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

## Running tests

```bash
mix test
```

All 14 tests are pure unit tests — no network calls, no credentials needed.

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

## Token cache behaviour

- APNs JWTs: cached 50 minutes (Apple allows up to 1 hour)
- FCM tokens: cached ~58 minutes (expire after 1 hour; margin of 5 min)
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
  key_id: "...", team_id: "...", bundle_id: "...",
  key_file: "/path/to/AuthKey.p8",  # OR key_pem: "..."
  env: :sandbox  # or :production

config :mob_push, :fcm,
  project_id: "...",
  service_account_key: "/path/to/sa.json"  # OR service_account_json: %{...}
```

## The install task

`mix mob_push.install` (plain Mix.Task, not Igniter — matches mob_dev style):
- Interactively prompts for APNs and FCM credentials
- Writes config stubs to `config/runtime.exs` with `System.get_env` wrappers
- Offers "skip" for each platform (inserts placeholder values)
- Explains where to get each credential as it prompts

## Dependencies

- `req ~> 0.5` — HTTP client (Finch-backed, HTTP/2 support)
- `jose ~> 1.11` — JWT signing (ES256 for APNs, RS256 for FCM)
- `jason ~> 1.4` — JSON
- `ex_doc` — docs only, dev/prod false

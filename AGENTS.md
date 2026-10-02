# AGENTS.md — orientation for AI agents working on mob_push

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

## Cross-repo work

**mob_notify:** the wire contract. Any change to the `{:push_token, ...}` shape, or the wake payload shape, must land in both repos' `test/fixtures/push_contract.exs` in the same session.

**mob_wake:** the identifier scheme. `MobWake.wake_payload/2` on the device side builds a payload map that mob_push then transports. Silent detection in `MobPush.FCM.build_message/2` (`content_available: true` AND no title/body/subtitle/sound/badge) is the switch that turns a regular push into a mob_wake-shaped one.

**Host apps:** `runtime.exs` is where credentials land. Prefer env-var opt-in (`APNS_KEY_FILE`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_ENV`, `FCM_SERVICE_ACCOUNT_KEY`, `FCM_PROJECT_ID`); config that unconditionally reads secrets breaks tests and CI.

## Testing

```bash
mix deps.get
mix test
```

All tests are pure unit tests — no network calls, no credentials. Bypass + real credentials would be needed for integration; not currently wired.

**When adding tests for APNs JWTs**, generate the EC key with `JOSE.JWK.generate_key({:ec, "P-256"})`. Do NOT use `:public_key.generate_key/1` — OTP-version quirks. Do NOT use `{:namedCurve, :prime256v1}` — use the OID tuple `{1, 2, 840, 10045, 3, 1, 7}`. The `apns_test.exs` has a private `build_aps/1` helper mirroring the module's; keep them in sync when adding payload fields.

## The pre-empt-failure rules that matter here

1. **APNs sandbox vs production is a namespace split, not a config option.** A token minted for `aps-environment=development` (Xcode debug build) works ONLY with `api.sandbox.push.apple.com`. Send it to production and you get `BadDeviceToken`. `config :mob_push, :apns, env: :sandbox` for dev-signed builds, `:production` for TestFlight / App Store. There is no dual-env mode in one config today; add it explicitly if a server needs both simultaneously.
2. **The `.p8` file is downloaded exactly once.** Apple's portal makes you download the auth key at creation; you cannot re-download it. `~/.mob/keys/` is a reasonable local location — copy to the server machine, `chmod 600`. Losing all copies means revoking + creating a new key.
3. **FCM `firebase-messaging` gradle plugin + `google-services.json` are host-level.** Plugin manifests can't contribute buildscript classpath entries — the mob_notify plugin declares these as `host_requirements` and mob_new's template ships them. If mob_push starts refusing sends with an FCM auth error, first check the host has both.
4. **Silent detection in `build_message/2` is order-sensitive.** `content_available: true` PLUS the absence of title/body/subtitle/sound/badge switches FCM to data-only mode (MOB-96) and APNs to `push_type: background` (MOB-84). Adding a visible field flips the wire back to a normal notification — sometimes that's what a caller wants (hybrid visible+silent) and sometimes it's a bug. The current tests cover both; keep them passing.
5. **APNs error strings map to atoms in `parse_error/1`** — keep it exhaustive. Apple has added new error codes over the years and a missing case falls through to `{:apns_error, "unknown"}` which is unhelpful.

## Pre-commit + release

```bash
mix format
mix credo --strict   # zero issues required, no exceptions
mix compile --warnings-as-errors
mix test
```

Same release trigger model as the rest of the mob ecosystem — `mix.exs` version bump on master triggers Hex publish via `.github/workflows/release.yml`. Do not bump versions without explicit permission. See `~/code/mob/RELEASE.md`.

# mob_push — Future Development Plan

## CLI credential setup tools

**Goal:** Users should never have to open a browser to configure push notifications.
Everything should be automated from the terminal.

### iOS — `mix mob_push.setup.apns`

Currently users must manually navigate the Apple Developer portal to:
1. Enable push on their App ID
2. Create an APNs Auth Key (.p8)
3. Note their Key ID, Team ID, and Bundle ID

**Proposed automation:**
- Use App Store Connect API (JWT-authenticated) to create and download the APNs Auth Key programmatically
- Auto-detect the Team ID from an existing Xcode project or `mob.exs`
- Auto-detect the Bundle ID from the app's `ios/<AppName>.xcodeproj`
- Write the credentials directly into `config/runtime.exs` and save the `.p8` to `~/.mob/keys/`
- Similar pattern to how `mix mob.setup.google_play` works for Google Play credentials

**Constraints:**
- App Store Connect API requires a separate API key (the user needs to create this once)
- Enabling push on an App ID may require a separate entitlement step
- Apple Developer portal APIs are not well-documented and may require screen-scraping fallbacks

### Android — `mix mob_push.setup.fcm`

Currently users must:
1. Create a Firebase project (or import a Google Cloud project)
2. Register the Android app in the project
3. Download `google-services.json`
4. Download a service account JSON key
5. Enable the FCM HTTP v1 API

**Proposed automation:**
- Use Google's REST APIs (Firebase Management API, Google Cloud IAM API) to:
  - Create or select a Firebase project
  - Register the Android app with the correct package name
  - Download `google-services.json` and place it at `android/app/google-services.json`
  - Create a service account with the `Firebase Cloud Messaging API` role
  - Download the service account JSON key
  - Enable the FCM API on the project
- Similar OAuth2 browser-flow approach to `mix mob.setup.google_play`
- Auto-detect the package name from `android/app/src/main/AndroidManifest.xml`

**APIs needed:**
- [Firebase Management API](https://firebase.google.com/docs/reference/firebase-management/rest) — create projects, register apps
- [Cloud IAM API](https://cloud.google.com/iam/docs/reference/rest) — create service accounts, bind roles
- [Service Account Credentials API](https://cloud.google.com/iam/docs/creating-managing-service-account-keys) — download keys
- [Service Usage API](https://cloud.google.com/service-usage/docs/reference/rest) — enable FCM API

### Shared OAuth2 flow

Both tools should share an OAuth2 browser-launch flow (already proven in `mix mob.setup.google_play`):
1. Open the browser to the OAuth2 consent page
2. Start a local HTTP server to receive the callback
3. Exchange the code for tokens
4. Use the tokens to call the relevant APIs

## Other future improvements

### Token fan-out helper

`mob_push` is intentionally scope-minimal (no storage), but a companion
`MobPush.Fanout` module could accept a token list and handle concurrent delivery
with automatic stale-token callbacks:

```elixir
MobPush.Fanout.send(tokens, payload, on_stale: &MyApp.PushTokens.delete/1)
```

### Notification channel registration (Android)

A Mix task or Mob.Enable feature that generates the Kotlin boilerplate for
registering notification channels in `MainActivity.onCreate`, so users don't
have to write it manually when using `channel_id` in their FCM payloads.

### APNs certificate support

Currently only token-based auth (`.p8`) is supported. Some older setups use
`.p12` certificate-based auth. Low priority — Apple encourages token-based auth
and `.p12` certs expire annually.

### Telemetry

Emit `:telemetry` events for send success/failure to integrate with
LiveDashboard and Prometheus exporters. Pattern: `[:mob_push, :send, :stop]`
with metadata `%{platform: :ios | :android, result: :ok | {:error, reason}}`.

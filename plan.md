# mob_push — Future Development Plan

## CLI credential setup tools

**Goal:** `mix mob_push.setup.apns` and `mix mob_push.setup.fcm` do all the
credential provisioning from the terminal. Users never have to navigate the
Apple Developer portal or Firebase console manually.

Both tools follow the pattern established by `mix mob.setup.google_play`:
numbered wizard steps, a `--dry-run` flag that narrates without acting, and a
final config block to paste into `config/runtime.exs`. Both are pure Mix tasks
with no compile-time deps on mob_dev (mob_push must remain standalone).

---

## `mix mob_push.setup.fcm` (Android)

### What it does

| Step | API | Automatable? |
|------|-----|-------------|
| Sign in to Google | OAuth2 browser flow (localhost callback) | ✓ |
| List/select Firebase project | Firebase Management API v1beta1 | ✓ |
| Create Firebase project | Firebase Management API v1beta1 | ✓ |
| Register Android app in project | Firebase Management API v1beta1 | ✓ |
| Download `google-services.json` | Firebase Management API v1beta1 | ✓ |
| Enable FCM HTTP v1 API | Service Usage API v1 | ✓ |
| Create `mob-fcm` service account | Cloud IAM API v1 | ✓ |
| Bind `roles/firebase.sdkAdminServiceAgent` | Cloud IAM API v1 | ✓ |
| Generate and save JSON key | Cloud IAM API v1 | ✓ |
| Write `config/runtime.exs` block | filesystem | ✓ |

**Everything is automatable.** No manual browser steps required.

### OAuth scopes

```
https://www.googleapis.com/auth/cloud-platform   ← GCP APIs (IAM, Service Usage)
https://www.googleapis.com/auth/firebase          ← Firebase Management API
```

### Auto-detection

Auto-detect the Android package name from (in order):
1. `mob.exs` → `config :mob_dev, bundle_id: "..."` (Android bundle ID)
2. `android/app/src/main/AndroidManifest.xml` → `package="..."` attribute
3. Prompt if neither is found

### REST APIs used

```
Firebase Management:
  GET  https://firebase.googleapis.com/v1beta1/projects
  POST https://firebase.googleapis.com/v1beta1/projects  (create new)
  POST https://firebase.googleapis.com/v1beta1/projects/{project}/androidApps
  GET  https://firebase.googleapis.com/v1beta1/projects/{project}/androidApps/{app}/config
       (returns google-services.json content as base64)

Service Usage:
  POST https://serviceusage.googleapis.com/v1/projects/{project}/services/fcm.googleapis.com:enable
  GET  https://serviceusage.googleapis.com/v1/{operation}  (poll until done)

Cloud IAM:
  POST https://iam.googleapis.com/v1/projects/{project}/serviceAccounts
  POST https://iam.googleapis.com/v1/projects/{project}/serviceAccounts/{email}:setIamPolicy
       OR
  POST https://cloudresourcemanager.googleapis.com/v1/projects/{project}:setIamPolicy
       (bind roles/firebase.sdkAdminServiceAgent to the service account)
  POST https://iam.googleapis.com/v1/projects/{project}/serviceAccounts/{email}/keys
```

### IAM role

The service account needs the `Firebase Cloud Messaging Admin` role:
`roles/firebase.sdkAdminServiceAgent`

This is a Firebase-specific role that grants send-only access to FCM.
It's narrower than `roles/editor` — use it.

### File outputs

- `android/app/google-services.json` — Firebase Android SDK config
- `~/.mob/keys/{app_name}-fcm-service-account.json` — service account key (mode 600)
- `config/runtime.exs` — config block appended

### Module structure

```
lib/mob_push/setup/
  fcm_wizard.ex         SetupWizard: run/1, step functions
  fcm_api.ex            Firebase/Cloud REST calls (all pure with token arg)
  google_oauth.ex       Browser OAuth2 flow (localhost callback)
  http.ex               Req-backed HTTP helpers (get/post, json_headers, ensure_started!)
lib/mix/tasks/
  mob_push.setup.fcm.ex Mix.Task wrapper
```

`google_oauth.ex` and `http.ex` are modelled directly on `MobDev.GooglePlay.OAuth`
and `MobDev.GooglePlay.HTTP`. They are separate modules (not imported from mob_dev)
to keep mob_push standalone. The implementation is small (~100 lines each) and the
duplication is intentional.

### OAuth client registration

Same challenge as the Google Play wizard: a Google OAuth "Desktop app" client
must be registered once at `console.cloud.google.com/apis/credentials`. Fill in
`@default_client_id` and `@default_client_secret` in `google_oauth.ex` after
registration. Users can override with env vars.

### Wizard output (happy path)

```
=== Mob FCM Setup ===

[auto-detected] Package name: com.example.myapp

── Step 1/6: Sign in to Google ──
  Opening browser to Google sign-in...
  Waiting for browser sign-in (120s timeout)...
  ✓ Signed in

── Step 2/6: Select Firebase project ──
  Found 2 Firebase projects:
    1. My App (my-app-a1b2c)
    2. Create new project
  Enter project number: 1
  ✓ Using: My App (my-app-a1b2c)

── Step 3/6: Register Android app ──
  ✓ Android app com.example.myapp already registered
  ✓ Downloaded google-services.json → android/app/google-services.json

── Step 4/6: Enable FCM HTTP v1 API ──
  Enabling fcm.googleapis.com... (may take up to 60s)
  ✓ FCM API enabled

── Step 5/6: Create service account ──
  ✓ Created mob-fcm@my-app-a1b2c.iam.gserviceaccount.com
  ✓ Granted roles/firebase.sdkAdminServiceAgent

── Step 6/6: Generate JSON key ──
  ✓ Key saved to ~/.mob/keys/myapp-fcm-service-account.json

=== Setup complete! ===

Add this to config/runtime.exs:

  config :mob_push, :fcm,
    project_id:          "my-app-a1b2c",
    service_account_key: System.get_env("FCM_SERVICE_ACCOUNT_KEY",
                           "/Users/you/.mob/keys/myapp-fcm-service-account.json")
```

---

## `mix mob_push.setup.apns` (iOS)

### The constraint: Apple has no API for APNs key creation

The App Store Connect API does not expose an endpoint to create APNs Auth Keys.
The `.p8` key can only be downloaded from
`developer.apple.com/account/resources/authkeys/add` in a browser.

This is a hard platform limit, not a tooling gap. Apple's keys page has no API
surface — not undocumented, genuinely absent.

### What can be automated anyway

| Step | Method | Automatable? |
|------|--------|-------------|
| Detect bundle_id from project | Read `mob.exs` / Xcode project | ✓ |
| Detect team_id from Xcode project | Parse `.xcodeproj/project.pbxproj` | ✓ |
| Enable push entitlement on App ID | App Store Connect API | ✓ (with ASC API key) |
| List existing APNs keys | App Store Connect API | ✓ (with ASC API key) |
| Create APNs Auth Key (.p8) | **No API — browser only** | ✗ |
| Watch Downloads for .p8 file | `File.stat` polling on `~/Downloads/` | ✓ |
| Move .p8 to `~/.mob/keys/` | filesystem | ✓ |
| Extract key_id from filename | string parse on `AuthKey_XXXXXXXXXX.p8` | ✓ |
| Write `config/runtime.exs` | filesystem | ✓ |

### Two modes of operation

**Mode A — guided (no ASC API key, default)**

Does not call any Apple API. Instead:
1. Auto-detects `bundle_id` and `team_id` from the Xcode project
2. Opens `developer.apple.com/account/resources/authkeys/add` in the browser
3. Tells the user exactly what to click (name, APNs checkbox)
4. Watches `~/Downloads/AuthKey_*.p8` — detects when the file appears
5. Moves it to `~/.mob/keys/`, parses the key_id from the filename
6. Writes the config block

This feels terminal-driven even though one click is required: the user doesn't
have to hunt for a portal page, know what to fill in, or remember where to save
the file. The wizard handles the rest.

**Mode B — API-assisted (`--asc-key path/to/asc-key.p8`)**

If the user already has an App Store Connect API key:
1. Uses it to call `GET /v1/bundleIds` and enable the push capability
2. Lists existing APNs keys via `GET /v1/bundleIds/{id}/capabilities`
3. Falls through to Mode A for the actual `.p8` download (still unavoidable)

Mode B is valuable for CI/team environments but Mode A covers the first-run experience.

### Auto-detection from project files

**`team_id`** — parse from `ios/<AppName>.xcodeproj/project.pbxproj`:
```
DEVELOPMENT_TEAM = Q89CW299G8;
```

**`bundle_id`** — in order:
1. `mob.exs` → `config :mob_dev, bundle_id: "..."`
2. `ios/<AppName>.xcodeproj/project.pbxproj` → `PRODUCT_BUNDLE_IDENTIFIER = com.example.myapp;`
3. Prompt

### Downloads watcher

Poll `~/Downloads/` every 2 seconds for up to 120 seconds after opening the browser:

```elixir
defp watch_for_p8_download(timeout_ms) do
  deadline = System.monotonic_time(:millisecond) + timeout_ms
  downloads = Path.expand("~/Downloads")
  do_watch(downloads, deadline)
end

defp do_watch(dir, deadline) do
  case File.ls!(dir) |> Enum.find(&String.match?(&1, ~r/^AuthKey_[A-Z0-9]{10}\.p8$/)) do
    nil ->
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(2_000)
        do_watch(dir, deadline)
      end
    filename ->
      {:ok, Path.join(dir, filename)}
  end
end
```

Extract key_id: `"AuthKey_XXXXXXXXXX.p8" |> Path.basename(".p8") |> String.replace_prefix("AuthKey_", "")`

### Wizard output (happy path, Mode A)

```
=== Mob APNs Setup ===

[auto-detected] Bundle ID: com.example.myapp
[auto-detected] Team ID:   Q89CW299G8

── Step 1/3: Create APNs Auth Key ──

  Opening Apple Developer portal → Keys page...
  https://developer.apple.com/account/resources/authkeys/add

  In the page that just opened:
    1. Enter a name, e.g. "My App APNs"
    2. Tick "Apple Push Notifications service (APNs)"
    3. Click Continue → Register
    4. Click Download

  Watching ~/Downloads for AuthKey_*.p8... (120s)
  ✓ Detected: AuthKey_YWS529LADZ.p8
  ✓ Moved to ~/.mob/keys/myapp-apns-AuthKey_YWS529LADZ.p8

── Step 2/3: APNs environment ──
  sandbox or production? [sandbox]: 

── Step 3/3: Write config ──
  ✓ Appended to config/runtime.exs

=== Setup complete! ===

  config :mob_push, :apns,
    key_id:    "YWS529LADZ",
    team_id:   "Q89CW299G8",
    bundle_id: "com.example.myapp",
    key_file:  System.get_env("APNS_KEY_FILE",
                 "/Users/you/.mob/keys/myapp-apns-AuthKey_YWS529LADZ.p8"),
    env:       if(config_env() == :prod, do: :production, else: :sandbox)
```

### Module structure

```
lib/mob_push/setup/
  apns_wizard.ex        SetupWizard: run/1, step functions, downloads watcher
  apns_api.ex           App Store Connect API calls (Mode B only)
  xcode_parser.ex       Parse team_id/bundle_id from .xcodeproj/project.pbxproj
lib/mix/tasks/
  mob_push.setup.apns.ex  Mix.Task wrapper
```

---

## Shared infrastructure

`lib/mob_push/setup/google_oauth.ex` and `lib/mob_push/setup/http.ex` are shared
between the FCM wizard and any future Google-API tools. They are independent copies
of the equivalent mob_dev modules — mob_push must not depend on mob_dev.

---

## Implementation order

1. **`http.ex`** — Req wrapper (get/post, json_headers, ensure_started!) — ~60 lines
2. **`google_oauth.ex`** — browser OAuth2 flow (copy of mob_dev pattern) — ~150 lines
3. **`fcm_api.ex`** — Firebase + GCP REST calls, each a pure function taking a token — ~200 lines
4. **`fcm_wizard.ex`** + **`mob_push.setup.fcm.ex`** — wizard driver + Mix.Task shell — ~300 lines
5. **`xcode_parser.ex`** — team_id/bundle_id detection from pbxproj — ~50 lines
6. **`apns_wizard.ex`** + **`mob_push.setup.apns.ex`** — wizard driver + Mix.Task shell — ~200 lines
7. **`apns_api.ex`** (Mode B) — App Store Connect API, add `--asc-key` flag — ~150 lines

Start with FCM (fully automatable, cleaner win). APNs Mode A is fast to build
(no API calls); Mode B is optional polish.

---

## Other future improvements

### Token fan-out helper

`mob_push` is intentionally scope-minimal (no storage), but a companion
`MobPush.Fanout` module could accept a token list and handle concurrent delivery
with automatic stale-token callbacks:

```elixir
MobPush.Fanout.send(tokens, payload, on_stale: &MyApp.PushTokens.delete/1)
```

### Notification channel registration (Android)

A `mix mob.enable notifications` feature (in mob_dev) that generates the Kotlin
boilerplate for registering notification channels in `MainActivity.onCreate`,
so users don't have to write it manually when using `channel_id` in FCM payloads.

### APNs certificate support

Currently only token-based auth (`.p8`) is supported. Some older setups use
`.p12` certificate-based auth. Low priority — Apple encourages token-based auth
and `.p12` certs expire annually.

### Telemetry

Emit `:telemetry` events for send success/failure to integrate with
LiveDashboard and Prometheus exporters. Pattern: `[:mob_push, :send, :stop]`
with metadata `%{platform: :ios | :android, result: :ok | {:error, reason}}`.

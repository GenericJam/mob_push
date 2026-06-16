# mob_push

Server-side push notifications for mobile apps built with [Mob](https://hexdocs.pm/mob) (or any app that uses APNs and FCM).

[![Hex.pm](https://img.shields.io/hexpm/v/mob_push.svg)](https://hex.pm/packages/mob_push)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/mob_push)

A focused Elixir library that wraps:
- **APNs HTTP/2** (iOS) — token-based auth with a `.p8` key
- **FCM HTTP v1** (Android) — OAuth2 via Google service account

Token storage and fan-out are intentionally out of scope — bring your own persistence.

## Installation

```elixir
def deps do
  [
    {:mob_push, "~> 0.2"}
  ]
end
```

### Guided setup (recommended)

Two interactive wizards handle the full credential flow without leaving your terminal:

**iOS (APNs):**

```bash
mix mob_push.setup.apns
```

The wizard:
1. Auto-detects your bundle ID and team ID from the Xcode project
2. Opens the Apple Developer portal → Keys page in your browser
3. Tells you exactly what to click (name, APNs checkbox, Download)
4. Watches `~/Downloads` for the `.p8` file and moves it to `~/.mob/keys/`
5. Prompts for sandbox or production
6. Appends the ready-to-use config block to `config/runtime.exs`

One click in the browser is unavoidable — Apple has no API for creating APNs Auth Keys.

Options: `--dry-run` to narrate steps without writing any files.

**Android (FCM):**

```bash
mix mob_push.setup.fcm
```

The wizard:
1. Opens your browser to Google sign-in (OAuth 2.0)
2. Lets you pick an existing Firebase project or create a new one
3. Registers your Android app and downloads `google-services.json`
4. Enables the FCM HTTP v1 API
5. Creates a `mob-fcm` service account with minimal IAM permissions
6. Generates a service-account JSON key and saves it to `~/.mob/keys/`
7. Appends the config block to `config/runtime.exs`

Options: `--dry-run` to narrate all steps without making any API calls or writing files.

### Fallback: manual onboarding task

If the wizards don't fit your environment, the original interactive install task
generates config stubs with `System.get_env` wrappers and step-by-step instructions:

```bash
mix mob_push.install
```

Options: `--ios-only`, `--android-only`, `--skip-all`.

Or configure the `config/runtime.exs` block completely by hand — see [Configuration](#configuration).

---

## Account setup

### iOS — Apple Developer account

Push notifications require a paid Apple Developer account ($99/year).

1. Enroll at [developer.apple.com/programs/enroll](https://developer.apple.com/programs/enroll/)
2. Individual accounts are approved instantly. Organisation accounts require a D-U-N-S number and can take several days.

Official docs: [Apple — Registering your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)

### Android — Firebase project

FCM is free. You need a Google account and a Firebase project:

1. Go to [console.firebase.google.com](https://console.firebase.google.com)
2. Click **Add project**, follow the wizard (~2 minutes)
3. Google Analytics is not required for push notifications

If you already have a Google Cloud project you can import it into Firebase instead of creating a new one.

Official docs: [Firebase — Add Firebase to your Android project](https://firebase.google.com/docs/android/setup)

---

## Getting your credentials

### iOS — APNs auth key

You need five things from the [Apple Developer portal](https://developer.apple.com/account):

**Step 1 — Enable push on your App ID**

- Go to *Certificates, Identifiers & Profiles → Identifiers*
- Select your app (or create one if you haven't yet)
- Under *Capabilities*, enable **Push Notifications** and save

Official docs: [Configuring push notifications](https://developer.apple.com/documentation/usernotifications/configuring-apns-with-certificates)

**Step 2 — Create an APNs Auth Key (.p8)**

- Go to *Certificates, Identifiers & Profiles → Keys*
- Click **+**, give it a name, tick **Apple Push Notifications service (APNs)**, click Continue → Register
- Click **Download** — Apple only lets you download it once. Store it safely (treat it like a private key).

Official docs: [Creating APNs authentication token signing key](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)

**Step 3 — Note your Key ID**

Shown next to the key name on the Keys list, and embedded in the downloaded filename (`AuthKey_XXXXXXXXXX.p8`). 10 characters, uppercase alphanumeric.

**Step 4 — Note your Team ID**

Shown in the top-right corner of the developer portal, and under *Membership Details*. 10 characters, uppercase alphanumeric.

**Step 5 — Note your Bundle ID**

Your app's bundle identifier — the one you used when creating the App ID, e.g. `com.example.myapp`. Found in *Identifiers*. Must match exactly what's in your Xcode project and what you pass to `Mob.Notify.register_push/1`.

### Android — FCM service account

**Step 1 — Open your Firebase project**

Go to [console.firebase.google.com](https://console.firebase.google.com) and select your project.

**Step 2 — Generate a service account key**

- Click the gear icon (⚙) → **Project Settings**
- Select the **Service accounts** tab
- Under *Firebase Admin SDK*, click **Generate new private key** → **Generate key**
- A JSON file is downloaded — store it safely (treat it like a password). It grants full FCM send access.

Official docs: [Firebase Admin SDK — Initialize the SDK](https://firebase.google.com/docs/admin/setup#initialize_the_sdk_in_non-google_environments)

**Step 3 — Note your Project ID**

Shown at the top of *Project Settings* (also visible in the Firebase console URL as `https://console.firebase.google.com/project/YOUR-PROJECT-ID`). Looks like `my-app-a1b2c`.

**Step 4 — Enable the FCM API (if needed)**

New Firebase projects have the FCM HTTP v1 API enabled by default, but if you see authentication errors, verify it:

- Go to [console.cloud.google.com/apis/library/fcm.googleapis.com](https://console.cloud.google.com/apis/library/fcm.googleapis.com)
- Select your project from the dropdown and click **Enable** if it isn't already enabled

**Step 5 — Add `google-services.json` to your Android project**

The Android Firebase SDK requires a `google-services.json` config file. Without it, the Android build will fail.

- In Firebase console → gear icon → **Project Settings** → **Your apps**
- Select your Android app (or click **Add app → Android** to register it — you'll need your app's package name, e.g. `com.example.myapp`)
- Click **Download google-services.json**
- Place the file at `android/app/google-services.json` in your Mob project

This file contains project identifiers (not credentials) and is generally safe to commit. Keep it out of public repos if your Firebase project has billing enabled.

---

## Configuration

Add to `config/runtime.exs` (recommended — keeps secrets out of source control):

```elixir
import Config

# iOS push notifications (APNs)
config :mob_push, :apns,
  key_id:    System.get_env("APNS_KEY_ID",    "YOUR_KEY_ID"),
  team_id:   System.get_env("APNS_TEAM_ID",   "YOUR_TEAM_ID"),
  bundle_id: System.get_env("APNS_BUNDLE_ID", "com.example.yourapp"),
  key_file:  System.get_env("APNS_KEY_FILE",  "/path/to/AuthKey_XXXXXXXXXX.p8"),
  env:       if(config_env() == :prod, do: :production, else: :sandbox)

# Android push notifications (FCM HTTP v1)
config :mob_push, :fcm,
  project_id:          System.get_env("FCM_PROJECT_ID",          "your-firebase-project-id"),
  service_account_key: System.get_env("FCM_SERVICE_ACCOUNT_KEY", "/path/to/service-account.json")
```

### APNs config reference

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `:key_id` | string | yes | 10-char Key ID from the Apple Developer portal Keys page |
| `:team_id` | string | yes | 10-char Team ID from Membership Details |
| `:bundle_id` | string | yes | Your app's bundle identifier, e.g. `com.example.myapp` |
| `:key_file` | string | one of | Path to the `.p8` auth key file on disk |
| `:key_pem` | string | one of | PEM string contents of the `.p8` key (alternative to `:key_file`) |
| `:env` | atom | no | `:sandbox` (default) or `:production`. Use `:sandbox` during development — APNs sandbox and production use different endpoints and different device tokens. |

**Sandbox vs production:** The sandbox APNs endpoint (`api.sandbox.push.apple.com`) only accepts tokens from apps installed via Xcode or TestFlight development builds. The production endpoint (`api.push.apple.com`) only accepts tokens from App Store or TestFlight production builds. Using the wrong environment returns a 403 or silently drops the notification.

### FCM config reference

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `:project_id` | string | yes | Firebase project ID (e.g. `my-app-a1b2c`) |
| `:service_account_key` | string | one of | Path to the service account JSON file on disk |
| `:service_account_json` | map | one of | Already-decoded service account map (alternative to file path, useful when credentials come from a secret manager) |

---

## Usage

### Before you start — app-side prerequisites

**iOS:** Make sure your App ID has push notifications enabled in the Apple Developer portal
(*Certificates, Identifiers & Profiles → Identifiers → your app → Push Notifications*),
then re-run `mix mob.provision` so the provisioning profile picks up the capability.
`mix mob.deploy --native` automatically mirrors `aps-environment` from the provisioning
profile into the app's codesigning entitlements — you don't need to create or edit any
entitlements file.

**Android:** Place `google-services.json` (downloaded from *Firebase console → Project
Settings → Your apps*) at `android/app/google-services.json`. The Android build fails
without it.

### Step 1 — Request permission and register in the app

In your Mob screen, call `Mob.Permissions.request/2` and `Mob.Notify.register_push/1`:

```elixir
defmodule MyApp.HomeScreen do
  use Mob.Screen

  @impl Mob.Screen
  def on_mount(socket) do
    socket = Mob.Permissions.request(socket, :notifications)
    {:ok, socket}
  end

  # The NIF sends a 2-tuple; forward it to the canonical 3-tuple handler.
  @impl Mob.Screen
  def handle_info({:permission, status}, socket) when status in [:granted, :denied] do
    handle_info({:permission, :notifications, status}, socket)
  end

  def handle_info({:permission, :notifications, :granted}, socket) do
    {:noreply, Mob.Notify.register_push(socket)}
  end

  def handle_info({:permission, :notifications, :denied}, socket) do
    {:noreply, socket}
  end

  def handle_info({:push_token, platform, token}, socket) do
    MyApp.PushTokens.upsert(socket.assigns.user_id, token, platform)
    {:noreply, socket}
  end
end
```

The `{:push_token, platform, token}` message arrives once the OS issues a registration token. `platform` is `:ios` or `:android`. Store the token alongside the platform — you need both when sending.

### Step 2 — Send a notification from your server

Call `MobPush.send/3` from anywhere on your server — a Phoenix controller, LiveView event, background job (Oban), etc.:

```elixir
# Basic alert
MobPush.send(device_token, :ios, %{
  title: "New message",
  body:  "Alice: Hey, are you free tonight?"
})

# With data payload
MobPush.send(device_token, :android, %{
  title: "New message",
  body:  "Alice: Hey, are you free tonight?",
  data:  %{screen: "chat", thread_id: "42"}
})

# iOS — badge count + sound
MobPush.send(device_token, :ios, %{
  title:    "3 new messages",
  body:     "Alice, Bob and 1 other",
  subtitle: "in #general",
  badge:    3,
  sound:    "default"
})

# iOS — silent background push (wakes app, no alert shown)
MobPush.send(device_token, :ios, %{
  title:             "",
  body:              "",
  content_available: true,
  data:              %{action: "sync"}
})

# Raise on failure instead of returning {:error, reason}
MobPush.send!(device_token, :android, %{title: "Hi", body: "World"})
```

### Payload options

| Key | Platforms | Type | Description |
|-----|-----------|------|-------------|
| `:title` | both | string | Notification title (required) |
| `:body` | both | string | Notification body text (required) |
| `:subtitle` | iOS | string | Second line under the title in the notification tray |
| `:data` | both | map | Arbitrary key-value pairs delivered to the app. Values are coerced to strings. |
| `:badge` | iOS | integer | Badge count shown on the app icon |
| `:sound` | iOS | string | `"default"` for the system sound, or a filename bundled in the app (without extension) |
| `:content_available` | iOS | boolean | Silent push — wakes the app in the background without showing an alert |
| `:android` | Android | map | Raw FCM `AndroidConfig` map — see [Notification appearance (Android)](#notification-appearance-android) |

### Return values

| Value | Meaning |
|-------|---------|
| `:ok` | Accepted by APNs / FCM (delivery is best-effort from here) |
| `{:error, :device_token_expired}` | APNs rejected — token is stale, deregister it |
| `{:error, :device_token_not_found}` | FCM rejected — token unknown, deregister it |
| `{:error, :auth_failed}` | Credentials rejected — check your config |
| `{:error, {:apns_error, reason}}` | APNs rejected with a reason string (e.g. `"BadDeviceToken"`, `"Unregistered"`) |
| `{:error, {:fcm_error, status, message}}` | FCM HTTP error |
| `{:error, :missing_apns_key_config}` | `:key_file` or `:key_pem` not set in config |
| `{:error, {:apns_key_file_unreadable, path, reason}}` | `.p8` file could not be read |
| `{:error, :missing_fcm_service_account_config}` | Neither `:service_account_key` nor `:service_account_json` is set |

---

## Notification delivery lifecycle

Understanding when and how your app receives the notification payload matters for building a good UX.

### Three delivery scenarios

**1. Foreground** — app is running and the screen is visible

The OS does not show a system notification. Mob intercepts the payload and sends `{:notification, notif}` directly to your screen process.

**2. Background** — app is running but hidden (user pressed Home)

The OS shows a system notification in the tray. When the user taps it, the app comes to the foreground and your screen receives `{:notification, notif}`.

**3. Killed** — app is not running

The OS shows a system notification. When tapped, the app launches fresh and `{:notification, notif}` is delivered to your screen once the BEAM has booted.

### Handling notifications in your screen

```elixir
def handle_info({:notification, notif}, socket) do
  # notif is a map with string keys:
  # %{"title" => "...", "body" => "...", "data" => %{"screen" => "chat"}}
  case get_in(notif, ["data", "screen"]) do
    "chat"    -> {:noreply, Mob.Socket.push_screen(socket, MyApp.ChatScreen)}
    "inbox"   -> {:noreply, Mob.Socket.push_screen(socket, MyApp.InboxScreen)}
    _         -> {:noreply, socket}
  end
end
```

### How delivery works under the hood (Android)

FCM carries two parallel payloads: a `notification` object (displayed by the OS when the app is killed/backgrounded) and a `data` object containing `mob_notification_json` — a JSON-encoded copy of the title, body, and data. This duplication is intentional:

- **Killed/backgrounded**: The OS displays the `notification` object. When tapped, Android puts `mob_notification_json` in the launch intent's extras. `MainActivity` reads it and delivers it to BEAM once it's running.
- **Foreground**: `MobFirebaseService.onMessageReceived` fires. It reads `mob_notification_json` from the data payload and delivers it to BEAM directly, bypassing the system tray.

This means your Elixir screen always gets a `{:notification, notif}` regardless of the app state — you don't need to write separate code paths for foreground vs. background.

---

## Notification appearance

### Android

Android notification appearance is controlled via the `:android` key in the payload, which maps directly to the FCM [`AndroidConfig`](https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages#androidconfig) and [`AndroidNotification`](https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages#androidnotification) objects.

```elixir
MobPush.send(token, :android, %{
  title: "New message",
  body:  "Alice: Hey!",
  data:  %{screen: "chat"},
  android: %{
    "notification" => %{
      "icon"       => "ic_notification",  # drawable resource name (no extension)
      "color"      => "#FF6200EE",        # accent color in #RRGGBB or #AARRGGBB
      "sound"      => "default",          # "default" or filename in res/raw/ (no extension)
      "channel_id" => "messages",         # notification channel (Android 8+)
      "image"      => "https://cdn.example.com/avatar.jpg",  # BigPictureStyle
      "tag"        => "msg-thread-42"     # replaces previous notification with same tag
    },
    "priority" => "high"  # "high" = wakes the screen; "normal" = quiet delivery
  }
})
```

#### Small icon

The small icon appears in the status bar and notification drawer. It **must be a white/transparent PNG** bundled as a drawable resource in your Android project — Android does not render colored icons in the status bar.

1. Create a white/transparent PNG at `android/app/src/main/res/drawable/ic_notification.png`
2. Reference it by name (without path or extension): `"icon" => "ic_notification"`

If no icon is specified, Android falls back to the app launcher icon, which is often rejected by newer Android versions with a grey box.

#### Accent color

Sets the circle background behind the small icon and the notification accent stripe. Hex string in `#RRGGBB` or `#AARRGGBB` format.

#### Notification channels (Android 8+)

Android 8 (API 26) introduced notification channels. Each channel has its own sound, vibration, and importance settings that the user can control in system settings. If you specify a `channel_id` that doesn't exist, the notification is silently dropped on Android 8+ devices.

Channels are created by your Android app at runtime — typically in `MainActivity.onCreate`. If you're using the Mob generator, add channel creation to your Kotlin setup code:

```kotlin
// In MainActivity.onCreate, before nativeStartBeam()
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
    val channel = NotificationChannel(
        "messages",
        "Messages",
        NotificationManager.IMPORTANCE_HIGH
    ).apply {
        description = "New message notifications"
    }
    getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
}
```

If you don't specify `channel_id`, FCM uses a default channel. The default channel uses the device's default sound and importance.

#### Large image (BigPictureStyle)

The `"image"` key displays a large image below the notification text. The URL must be publicly accessible over HTTPS. Android downloads it at display time.

#### Delivery priority

`"priority" => "high"` causes the notification to wake the screen and appear as a heads-up notification. `"normal"` (the default) delivers quietly. Note: this is the FCM *delivery* priority, separate from the notification display importance set on the channel.

### iOS

iOS notification appearance is controlled by the standard payload keys:

| Key | Type | Description |
|-----|------|-------------|
| `:title` | string | Bold first line |
| `:subtitle` | string | Lighter second line, below the title |
| `:body` | string | Main notification text |
| `:badge` | integer | Badge count on the app icon. Pass `0` to clear. |
| `:sound` | string | `"default"` for the system sound, or a filename (without extension) bundled in the app's main bundle |

#### Custom sounds (iOS)

Bundle an `.aiff`, `.wav`, or `.caf` file in your Xcode project (add it to the app target, not a folder reference). Pass the filename without extension as `:sound`. Sounds longer than 30 seconds play the default sound instead.

#### Images (iOS)

iOS requires a **Notification Service Extension** (NSE) to attach images. The NSE is a separate build target in Xcode that intercepts the notification before display, downloads the image from a URL you include in the `:data` map, and attaches it. This is an app-side build step and is not handled by `mob_push`. See [Apple's UNNotificationServiceExtension docs](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension) for setup.

---

## Token management

### Storing tokens

Persist tokens in your database or ETS. Each user may have multiple tokens (multiple devices, or the same device reinstalled). Always store the platform alongside the token:

```elixir
# Schema example
# push_tokens: user_id, platform (:ios | :android), token, inserted_at, updated_at

def handle_info({:push_token, platform, token}, socket) do
  MyApp.PushTokens.upsert(%{
    user_id:  socket.assigns.user_id,
    platform: platform,
    token:    token
  })
  {:noreply, socket}
end
```

### Token expiry and deregistration

Tokens become invalid when:
- The user uninstalls and reinstalls the app
- The user restores the device from backup
- APNs/FCM rotates the token (rare but possible)

When `MobPush.send/3` returns `:device_token_expired` or `:device_token_not_found`, delete the token immediately to avoid sending to it again:

```elixir
case MobPush.send(token, platform, payload) do
  :ok ->
    :ok
  {:error, reason} when reason in [:device_token_expired, :device_token_not_found] ->
    MyApp.PushTokens.delete(token)
  {:error, reason} ->
    Logger.warning("Push failed: #{inspect(reason)}")
end
```

### Fan-out to multiple devices

```elixir
def notify_user(user_id, payload) do
  user_id
  |> MyApp.PushTokens.list()
  |> Enum.each(fn %{token: token, platform: platform} ->
    case MobPush.send(token, platform, payload) do
      :ok ->
        :ok
      {:error, reason} when reason in [:device_token_expired, :device_token_not_found] ->
        MyApp.PushTokens.delete(token)
      {:error, reason} ->
        Logger.warning("Push to #{platform} failed for user #{user_id}: #{inspect(reason)}")
    end
  end)
end
```

For high-volume fan-out, run sends concurrently with `Task.async_stream/3` and set a reasonable concurrency limit.

---

## Token caching

APNs JWTs (valid 1 hour) and FCM OAuth2 tokens (valid 1 hour) are cached in ETS and refreshed automatically 5 minutes before expiry. The `MobPush.TokenCache` GenServer is started automatically by the `MobPush` application — no setup needed.

If a 401 or 403 is received from APNs or FCM, the cached token is evicted and a fresh one is fetched on the next call. This handles the rare case where a token is invalidated server-side before its expiry.

---

## Sandbox vs production (iOS)

APNs has two separate environments — sandbox and production — with different URLs and different device token namespaces:

- **Sandbox** (`api.sandbox.push.apple.com`): for apps installed via Xcode or TestFlight development builds
- **Production** (`api.push.apple.com`): for App Store builds and TestFlight production builds

A sandbox token sent to the production endpoint (or vice versa) returns `{:error, {:apns_error, "BadDeviceToken"}}`. The standard pattern is:

```elixir
env: if(config_env() == :prod, do: :production, else: :sandbox)
```

If you're testing TestFlight production builds, you need `:production` in your `:staging` / `:prod` environment.

---

## Development

Clone, then run once:

```bash
mix setup
```

That fetches deps and activates the repo's git hooks (`.githooks/pre-push`):
`mix format --check`, `mix credo --strict` (incl. ExSlop), and `mix compile --warnings-as-errors` run on every push, plus the full test
suite when `mix.exs` changes — the same gate CI enforces before publishing.

## License

MIT

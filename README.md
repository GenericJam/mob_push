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
    {:mob_push, "~> 0.1"}
  ]
end
```

Run the onboarding task to generate config stubs and get step-by-step setup guidance:

```bash
mix mob_push.install
```

Or configure manually (see below).

---

## Account setup

### iOS — Apple Developer account

Push notifications require a paid Apple Developer account ($99/year). If you don't have one yet:

1. Enroll at [developer.apple.com/programs/enroll](https://developer.apple.com/programs/enroll/)
2. Individual accounts are approved instantly. Organisation accounts require a D-U-N-S number and can take several days.

Official docs: [Apple — Registering your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)

### Android — Firebase project

FCM is free. You need a Google account and a Firebase project:

1. Go to [console.firebase.google.com](https://console.firebase.google.com)
2. Click **Add project**, follow the wizard (3 steps, takes ~2 minutes)
3. You don't need Google Analytics enabled for push notifications

If you already have a Google Cloud project you can import it into Firebase instead of creating a new one.

Official docs: [Firebase — Add Firebase to your Android project](https://firebase.google.com/docs/android/setup)

---

## Getting your credentials

### iOS — APNs auth key

You need four things from the [Apple Developer portal](https://developer.apple.com/account):

**1. Enroll your App ID for push**

- Go to *Certificates, Identifiers & Profiles → Identifiers*
- Select your app (or create one if you haven't yet)
- Under *Capabilities*, enable **Push Notifications** and save

Official docs: [Configuring push notifications](https://developer.apple.com/documentation/usernotifications/configuring-apns-with-certificates)

**2. Create an APNs Auth Key (.p8)**

- Go to *Certificates, Identifiers & Profiles → Keys*
- Click **+**, give it a name, tick **Apple Push Notifications service (APNs)**, click Continue → Register
- Click **Download** — this is the only time Apple lets you download it. Store it safely.

Official docs: [Creating APNs authentication token signing key](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)

**3. Note your Key ID**

Shown next to the key name on the Keys list, and embedded in the downloaded filename (`AuthKey_XXXXXXXXXX.p8`). 10 characters.

**4. Note your Team ID**

Shown in the top-right corner of the developer portal, and under *Membership Details*. 10 characters.

**5. Note your Bundle ID**

Your app's bundle identifier — the one you used when creating the App ID, e.g. `com.example.myapp`. Found in *Identifiers*.

### Android — FCM service account

**1. Open your Firebase project**

Go to [console.firebase.google.com](https://console.firebase.google.com) and select your project.

**2. Generate a service account key**

- Click the gear icon → **Project Settings**
- Select the **Service accounts** tab
- Click **Generate new private key** → **Generate key**
- A JSON file is downloaded — store it safely (treat it like a password)

Official docs: [Firebase Admin SDK — Initialize the SDK](https://firebase.google.com/docs/admin/setup#initialize_the_sdk_in_non-google_environments)

**3. Note your Project ID**

Shown at the top of *Project Settings* (also visible in the Firebase console URL). Looks like `my-app-a1b2c`.

**4. Enable the FCM API**

The FCM HTTP v1 API must be enabled on your Google Cloud project (it usually is by default for new Firebase projects, but worth checking):

- Go to [console.cloud.google.com/apis/library/fcm.googleapis.com](https://console.cloud.google.com/apis/library/fcm.googleapis.com)
- Select your project and click **Enable** if it isn't already

Official docs: [Firebase Cloud Messaging HTTP v1 API](https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages/send)

**5. Add `google-services.json` to your Android project**

The Firebase SDK requires a `google-services.json` config file in your Android app directory. Without it the Android build will fail.

- In the Firebase console, click the gear icon → **Project Settings**
- Under **Your apps**, select your Android app (or click **Add app → Android** if you haven't registered it yet)
- Click **Download google-services.json**
- Place the file at `android/app/google-services.json` in your Mob project

This file is not a secret (it contains only project identifiers, not credentials), but it is typically kept out of source control if you are working in a public repository.

Official docs: [Add Firebase to your Android project](https://firebase.google.com/docs/android/setup)

---

## Configuration

Add to `config/runtime.exs` (recommended — keeps secrets out of source control):

```elixir
# iOS push notifications (APNs)
config :mob_push, :apns,
  key_id:    System.get_env("APNS_KEY_ID",     "YOUR_KEY_ID"),
  team_id:   System.get_env("APNS_TEAM_ID",    "YOUR_TEAM_ID"),
  bundle_id: System.get_env("APNS_BUNDLE_ID",  "com.example.yourapp"),
  key_file:  System.get_env("APNS_KEY_FILE",   "/path/to/AuthKey_XXXXXXXXXX.p8"),
  env:       if(config_env() == :prod, do: :production, else: :sandbox)

# Android push notifications (FCM HTTP v1)
config :mob_push, :fcm,
  project_id:          System.get_env("FCM_PROJECT_ID",          "your-firebase-project"),
  service_account_key: System.get_env("FCM_SERVICE_ACCOUNT_KEY", "/path/to/service-account.json")
```

| Config key | Description |
|---|---|
| `:apns → :key_id` | 10-char Key ID from Apple Developer portal |
| `:apns → :team_id` | 10-char Team ID from your Apple account |
| `:apns → :bundle_id` | Your app's bundle ID, e.g. `com.example.app` |
| `:apns → :key_file` | Path to the `.p8` auth key file on disk |
| `:apns → :key_pem` | PEM string (alternative to `:key_file`) |
| `:apns → :env` | `:sandbox` (default) or `:production` |
| `:fcm → :project_id` | Firebase project ID |
| `:fcm → :service_account_key` | Path to service account JSON on disk |
| `:fcm → :service_account_json` | Already-decoded map (alternative to file path) |

---

## Usage

### Receiving tokens from the device

In your Mob screen, `handle_info/2` receives the push token once the user grants notification permission:

```elixir
def handle_info({:push_token, token}, socket) do
  platform = :rpc.call(node(), :mob_nif, :platform, [])
  MyApp.PushTokens.upsert(socket.assigns.user_id, token, platform)
  {:noreply, socket}
end
```

### Sending a notification

Call from your server (Phoenix controller, LiveView, background job, etc.):

```elixir
# Basic alert
MobPush.send(device_token, :ios, %{
  title: "New message",
  body:  "Alice: Hey, are you free tonight?"
})

# With data payload (your app reads this on launch/foreground)
MobPush.send(device_token, :android, %{
  title: "New message",
  body:  "Alice: Hey, are you free tonight?",
  data:  %{screen: "chat", thread_id: "42"}
})

# iOS — badge + sound
MobPush.send(device_token, :ios, %{
  title:  "3 new messages",
  body:   "Alice, Bob and 1 other",
  badge:  3,
  sound:  "default",
  data:   %{screen: "inbox"}
})

# iOS — silent background push (wakes app, no alert shown)
MobPush.send(device_token, :ios, %{
  title:             "",
  body:              "",
  content_available: true,
  data:              %{action: "sync"}
})

# Raise on failure
MobPush.send!(device_token, :ios, %{title: "Hi", body: "World"})
```

### Return values

| Value | Meaning |
|---|---|
| `:ok` | Accepted by APNs / FCM |
| `{:error, :device_token_expired}` | Token is stale — deregister it |
| `{:error, :device_token_not_found}` | FCM doesn't know this token — deregister it |
| `{:error, :auth_failed}` | Credentials rejected — check config |
| `{:error, {:apns_error, reason}}` | APNs rejected with reason string |
| `{:error, {:fcm_error, status, message}}` | FCM error response |
| `{:error, :missing_apns_key_config}` | `:key_file` or `:key_pem` not configured |

### Fan-out to multiple devices

```elixir
def notify_user(user_id, payload) do
  MyApp.PushTokens.list(user_id)
  |> Enum.each(fn %{token: token, platform: platform} ->
    case MobPush.send(token, platform, payload) do
      :ok ->
        :ok
      {:error, reason} when reason in [:device_token_expired, :device_token_not_found] ->
        MyApp.PushTokens.delete(token)
      {:error, reason} ->
        Logger.warning("Push failed for user #{user_id}: #{inspect(reason)}")
    end
  end)
end
```

---

## Token caching

APNs JWTs and FCM OAuth2 tokens are cached in ETS and refreshed automatically 5 minutes before expiry. The mob_push supervision tree handles this — no setup needed. If a 401/403 is received, the cache is evicted and a fresh token is fetched on the next call.

---

## License

MIT

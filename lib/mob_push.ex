defmodule MobPush do
  @moduledoc """
  Server-side push notifications for Mob apps.

  A thin server library that wraps:
  - **APNs HTTP/2** (iOS) — token-based auth with a p8 key
  - **FCM HTTP v1** (Android) — OAuth2 via Google service account

  Token storage and fan-out are out of scope — bring your own persistence.

  ## Setup

  Add to your `mix.exs`:

      {:mob_push, "~> 0.1"}

  ### iOS (APNs)

  In Apple Developer portal, create an APNs Auth Key (`.p8` file) and note
  your Key ID and Team ID. Then configure:

      config :mob_push, :apns,
        key_id:    "XXXXXXXXXX",
        team_id:   "XXXXXXXXXX",
        key_file:  "/run/secrets/apns_auth_key.p8",
        bundle_id: "com.example.myapp",
        env:       :production   # :sandbox | :production

  ### Android (FCM)

  In Firebase console → Project Settings → Service Accounts → Generate new
  private key. Download the JSON file, then configure:

      config :mob_push, :fcm,
        project_id:          "my-firebase-project",
        service_account_key: "/run/secrets/fcm_service_account.json"

  ### Getting device tokens from the app

  The Mob library calls these NIF functions on the native side:
  - **iOS**: `mob_send_push_token(hexToken)` from `didRegisterForRemoteNotificationsWithDeviceToken`
  - **Android**: `NotificationReceiver` BroadcastReceiver — token arrives as `{:push_token, token}`

  These send `{:push_token, token}` to your `Mob.Screen` process. Store it
  however you like (ETS, database, etc.) and pass it to `MobPush.send/3`.

  ## Usage

      # Store tokens from handle_info/2 in your screen
      def handle_info({:push_token, token}, socket) do
        MyApp.PushTokens.save(socket.assigns.user_id, token, :ios)
        {:noreply, socket}
      end

      # Send from your server (not from the app process)
      MobPush.send("device_token_hex", :ios, %{
        title: "New message",
        body:  "You have a new message from Alice",
        data:  %{screen: "messages", thread_id: "42"}
      })

      MobPush.send("fcm_registration_token", :android, %{
        title: "New message",
        body:  "You have a new message",
        data:  %{screen: "messages", thread_id: "42"}
      })

  ## Payload options

  | Key                  | Type    | Description                                      |
  |----------------------|---------|--------------------------------------------------|
  | `:title`             | string  | Notification title (required)                    |
  | `:body`              | string  | Notification body text (required)                |
  | `:data`              | map     | Arbitrary key-value data passed to the app       |
  | `:badge`             | integer | iOS badge count                                  |
  | `:sound`             | string  | Sound name (`"default"` for system default)      |
  | `:content_available` | boolean | iOS silent push (wakes app in background)        |
  | `:android`           | map     | Raw FCM `android` message config                 |

  ## Return values

  - `:ok` — notification accepted by APNs / FCM
  - `{:error, :device_token_expired}` — token is no longer valid (deregister it)
  - `{:error, :device_token_not_found}` — token unknown to FCM (deregister it)
  - `{:error, :auth_failed}` — credentials rejected; check your config
  - `{:error, {:apns_error, reason}}` — APNs rejected with `reason` string
  - `{:error, {:fcm_error, status, message}}` — FCM error response
  """

  @doc """
  Send a push notification to a device.

  `platform` is `:ios` or `:android`.

  `payload` must include `:title` and `:body`. Optional keys: `:data`,
  `:badge`, `:sound`, `:content_available`, `:android`.
  """
  @spec send(device_token :: String.t(), platform :: :ios | :android, payload :: map()) ::
          :ok | {:error, term()}
  def send(device_token, :ios, payload), do: MobPush.APNS.send(device_token, payload)
  def send(device_token, :android, payload), do: MobPush.FCM.send(device_token, payload)
  def send(_token, platform, _payload), do: {:error, {:unknown_platform, platform}}

  @doc """
  Like `send/3` but raises on error.
  """
  @spec send!(String.t(), :ios | :android, map()) :: :ok
  def send!(device_token, platform, payload) do
    case send(device_token, platform, payload) do
      :ok -> :ok
      {:error, reason} -> raise "MobPush.send!/3 failed: #{inspect(reason)}"
    end
  end
end

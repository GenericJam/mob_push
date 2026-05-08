defmodule MobPush do
  @moduledoc """
  Server-side push notifications for Mob apps.

  A thin server library that wraps:
  - **APNs HTTP/2** (iOS) — token-based auth with a `.p8` key
  - **FCM HTTP v1** (Android) — OAuth2 via Google service account

  Token storage and fan-out are intentionally out of scope — bring your own persistence.

  ## Setup

  Add to your `mix.exs`:

      {:mob_push, "~> 0.1"}

  Then run `mix mob_push.install` for interactive credential setup, or configure
  manually in `config/runtime.exs`:

      # iOS
      config :mob_push, :apns,
        key_id:    "XXXXXXXXXX",         # 10-char Key ID from Apple Developer portal
        team_id:   "XXXXXXXXXX",         # 10-char Team ID from Membership Details
        bundle_id: "com.example.myapp",
        key_file:  "/run/secrets/AuthKey_XXXXXXXXXX.p8",
        env:       :production           # :sandbox | :production

      # Android
      config :mob_push, :fcm,
        project_id:          "my-firebase-project",
        service_account_key: "/run/secrets/fcm_service_account.json"

  See the README for the full credential walkthrough.

  ## Receiving device tokens in the app

  In your `Mob.Screen`, request permission and register for push:

      def on_mount(socket) do
        socket = Mob.Permissions.request(socket, :notifications)
        {:ok, socket}
      end

      def handle_info({:permission, :notifications, :granted}, socket) do
        {:noreply, Mob.Notify.register_push(socket)}
      end

      def handle_info({:push_token, platform, token}, socket) do
        MyApp.PushTokens.upsert(socket.assigns.user_id, token, platform)
        {:noreply, socket}
      end

  ## Sending notifications

      MobPush.send(token, :ios, %{
        title:    "New message",
        body:     "Alice: Hey, are you free tonight?",
        subtitle: "in #general",
        badge:    3,
        sound:    "default",
        data:     %{screen: "chat", thread_id: "42"}
      })

      MobPush.send(token, :android, %{
        title: "New message",
        body:  "Alice: Hey, are you free tonight?",
        data:  %{screen: "chat", thread_id: "42"},
        android: %{
          "notification" => %{
            "icon"       => "ic_notification",
            "color"      => "#FF6200EE",
            "channel_id" => "messages"
          }
        }
      })

  ## Handling received notifications in the app

  All three delivery scenarios (foreground, background tap, killed-then-tapped)
  deliver the same `{:notification, notif}` message to your screen:

      def handle_info({:notification, notif}, socket) do
        # notif has string keys: "title", "body", "data"
        case get_in(notif, ["data", "screen"]) do
          "chat"  -> {:noreply, Mob.Socket.push_screen(socket, MyApp.ChatScreen)}
          _       -> {:noreply, socket}
        end
      end

  ## Payload options

  | Key                  | Platforms | Type    | Description                                          |
  |----------------------|-----------|---------|------------------------------------------------------|
  | `:title`             | both      | string  | Notification title (required)                        |
  | `:body`              | both      | string  | Notification body text (required)                    |
  | `:subtitle`          | iOS       | string  | Second line under the title                          |
  | `:data`              | both      | map     | Arbitrary key-value pairs delivered to the app       |
  | `:badge`             | iOS       | integer | Badge count on the app icon (0 to clear)             |
  | `:sound`             | iOS       | string  | `"default"` or a filename bundled in the app         |
  | `:content_available` | iOS       | boolean | Silent push — wakes app in background, no alert      |
  | `:android`           | Android   | map     | Raw FCM `AndroidConfig` for appearance customization |

  ## Return values

  - `:ok` — accepted by APNs / FCM
  - `{:error, :device_token_expired}` — stale APNs token; delete it
  - `{:error, :device_token_not_found}` — FCM doesn't know this token; delete it
  - `{:error, :auth_failed}` — credentials rejected; check your config
  - `{:error, {:apns_error, reason}}` — APNs rejected with a reason string
  - `{:error, {:fcm_error, status, message}}` — FCM HTTP error
  - `{:error, :missing_apns_key_config}` — `:key_file` / `:key_pem` not configured
  - `{:error, {:apns_key_file_unreadable, path, reason}}` — `.p8` file not readable
  - `{:error, :missing_fcm_service_account_config}` — service account not configured
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

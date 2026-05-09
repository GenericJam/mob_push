defmodule MobPush.FCM do
  @moduledoc """
  FCM HTTP v1 adapter for MobPush.

  Sends push notifications to Android devices via Firebase Cloud Messaging
  HTTP v1 API using a Google service account for OAuth2 authentication. Called
  internally by `MobPush.send/3` — you can also call it directly for advanced
  use cases.

  ## Configuration

      config :mob_push, :fcm,
        project_id:          "my-firebase-project",   # Firebase project ID
        service_account_key: "/path/to/service-account.json"
        # OR: service_account_json: %{...}  # already-decoded map (from secret manager, etc.)

  The service account JSON is downloaded from Firebase console:
  Project Settings → Service Accounts → Generate new private key.

  ## Payload options

  | Key       | Type   | Description |
  |-----------|--------|-------------|
  | `:title`  | string | Notification title (required) |
  | `:body`   | string | Notification body text (required) |
  | `:data`   | map    | Arbitrary key-value pairs delivered to the app. Keys and values are coerced to strings (FCM data payload requirement). |
  | `:android`| map    | Raw FCM `AndroidConfig` map — see below for appearance options. |

  ## Android notification appearance

  Pass an `:android` key with a nested `"notification"` map for appearance
  customization. This is forwarded verbatim as the FCM
  [`AndroidConfig`](https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages#androidconfig):

      MobPush.send(token, :android, %{
        title: "New message",
        body:  "Alice: Hey!",
        android: %{
          "notification" => %{
            "icon"       => "ic_notification",  # drawable resource name (no path/extension)
            "color"      => "#FF6200EE",        # accent color — #RRGGBB or #AARRGGBB
            "sound"      => "default",          # "default" or res/raw/ filename (no extension)
            "channel_id" => "messages",         # notification channel ID (Android 8+)
            "image"      => "https://...",      # HTTPS URL for BigPictureStyle large image
            "tag"        => "msg-thread-42"     # replaces previous notification with same tag
          },
          "priority" => "high"   # "high" wakes screen; "normal" delivers quietly
        }
      })

  ### Small icon

  The small icon appears in the status bar. It must be a white/transparent PNG
  bundled as a drawable resource at `android/app/src/main/res/drawable/`. Pass
  the filename without path or extension. Android rejects colored icons in the
  status bar — design it as a white silhouette on a transparent background.

  ### Notification channels (Android 8+)

  Each channel has its own sound and importance settings controlled by the user.
  A notification sent to a non-existent `channel_id` is silently dropped on
  Android 8+ devices. Create channels in `MainActivity.onCreate` (Kotlin):

      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
          val channel = NotificationChannel("messages", "Messages", NotificationManager.IMPORTANCE_HIGH)
          getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
      }

  If `channel_id` is omitted, FCM uses a default channel.

  ## Delivery mechanism and `mob_notification_json`

  FCM sends two parallel payloads to the device:

  1. **`notification` object** — displayed by the Android OS when the app is
     killed or backgrounded. The system reads `title` and `body` from here.

  2. **`data` object** — always delivered to the app, regardless of foreground/
     background/killed state. Contains `mob_notification_json`, a JSON-encoded
     copy of the title, body, source, and data map.

  This duplication is intentional. When the app is killed and the user taps the
  notification, Android puts the intent extras (including `mob_notification_json`)
  into `MainActivity`'s launch intent. The BEAM reads it on startup and delivers
  `{:notification, notif}` to your screen. When the app is in the foreground,
  `MobFirebaseService.onMessageReceived` fires and reads `mob_notification_json`
  from the data payload directly. Your screen always receives the same
  `{:notification, notif}` message regardless of which path was used.

  ## Authentication

  Uses RS256 JWT tokens signed with the service account private key, exchanged
  for a short-lived OAuth2 access token at `oauth2.googleapis.com/token`. Access
  tokens are valid for 1 hour; `MobPush.TokenCache` refreshes them 5 minutes
  early. On a 401, the token is evicted and a fresh one is fetched next call.

  ## Usage

      MobPush.FCM.send("fcm_registration_token", %{
        title: "New message",
        body:  "Alice: Hey, are you free tonight?",
        data:  %{screen: "chat", thread_id: "42"},
        android: %{
          "notification" => %{"icon" => "ic_notification", "color" => "#FF6200EE"},
          "priority" => "high"
        }
      })
  """

  @fcm_url "https://fcm.googleapis.com/v1/projects"
  @token_url "https://oauth2.googleapis.com/token"
  @scope "https://www.googleapis.com/auth/firebase.messaging"

  @doc "Send a push notification to an Android device token."
  @spec send(device_token :: String.t(), payload :: map()) :: :ok | {:error, term()}
  def send(device_token, payload) do
    cfg = config()

    with {:ok, sa} <- service_account(cfg),
         {:ok, access_token} <- oauth_token(sa) do
      url = "#{@fcm_url}/#{cfg[:project_id]}/messages:send"
      body = build_message(device_token, payload)

      req =
        Req.new(
          finch: MobPush.Finch,
          url: url,
          headers: [
            {"authorization", "Bearer #{access_token}"},
            {"content-type", "application/json"}
          ],
          body: body
        )

      case Req.post(req) do
        {:ok, %{status: 200}} ->
          :ok

        {:ok, %{status: 401}} ->
          MobPush.TokenCache.evict({:fcm_token, sa["client_email"]})
          {:error, :auth_failed}

        {:ok, %{status: 404}} ->
          {:error, :device_token_not_found}

        {:ok, %{status: status, body: body}} ->
          {:error, {:fcm_error, status, parse_error(body)}}

        {:error, _} = err ->
          err
      end
    end
  end

  # ── OAuth2 token ───────────────────────────────────────────────────────────

  defp oauth_token(sa) do
    MobPush.TokenCache.get({:fcm_token, sa["client_email"]}, fn ->
      fetch_oauth_token(sa)
    end)
  end

  defp fetch_oauth_token(sa) do
    now = System.system_time(:second)

    claims = %{
      "iss" => sa["client_email"],
      "sub" => sa["client_email"],
      "aud" => @token_url,
      "scope" => @scope,
      "iat" => now,
      "exp" => now + 3600
    }

    with {:ok, jwt} <- sign_service_account_jwt(sa, claims),
         {:ok, token, expires_in} <- exchange_jwt(jwt) do
      {:ok, {token, now + expires_in - 60}}
    end
  end

  defp sign_service_account_jwt(sa, claims) do
    jwk = JOSE.JWK.from_pem(sa["private_key"])
    header = %{"alg" => "RS256"}
    {_, token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, header, claims))
    {:ok, token}
  rescue
    e -> {:error, {:jwt_sign_error, Exception.message(e)}}
  end

  defp exchange_jwt(jwt) do
    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    req =
      Req.new(
        finch: MobPush.Finch,
        url: @token_url,
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: body
      )

    case Req.post(req) do
      {:ok, %{status: 200, body: resp}} ->
        token = resp["access_token"] || resp[:access_token]
        expires_in = resp["expires_in"] || resp[:expires_in] || 3600
        {:ok, token, expires_in}

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_exchange_failed, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ── Message building ───────────────────────────────────────────────────────

  defp build_message(device_token, %{title: title, body: body} = payload) do
    notification = %{"title" => title, "body" => body}
    data = Map.get(payload, :data, %{})

    # mob_notification_json lets MainActivity reconstruct the notification when
    # the user taps it from the system tray (background/killed state).
    # MobFirebaseService.onMessageReceived uses it for foreground delivery.
    mob_json =
      Jason.encode!(%{
        "title" => title,
        "body" => body,
        "source" => "push",
        "data" => Map.new(data, fn {k, v} -> {to_string(k), to_string(v)} end)
      })

    android_data =
      data
      |> stringify_keys()
      |> Map.put("mob_notification_json", mob_json)

    message = %{
      "token" => device_token,
      "notification" => notification,
      "data" => android_data
    }

    # Android-specific options
    message =
      if android_opts = Map.get(payload, :android) do
        Map.put(message, "android", android_opts)
      else
        message
      end

    Jason.encode!(%{"message" => message})
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp parse_error(body) when is_map(body) do
    get_in(body, ["error", "message"]) || inspect(body)
  end

  defp parse_error(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_error(decoded)
      _ -> body
    end
  end

  defp parse_error(body), do: inspect(body)

  defp service_account(cfg) do
    cond do
      sa = cfg[:service_account_json] -> {:ok, sa}
      path = cfg[:service_account_key] -> read_service_account(path)
      true -> {:error, :missing_fcm_service_account_config}
    end
  end

  defp read_service_account(path) do
    case File.read(path) do
      {:ok, json} -> decode_service_account(json, path)
      {:error, reason} -> {:error, {:fcm_service_account_unreadable, path, reason}}
    end
  end

  defp decode_service_account(json, path) do
    case Jason.decode(json) do
      {:ok, sa} -> {:ok, sa}
      {:error, reason} -> {:error, {:fcm_service_account_invalid_json, path, reason}}
    end
  end

  defp config do
    Application.get_env(:mob_push, :fcm, [])
  end
end

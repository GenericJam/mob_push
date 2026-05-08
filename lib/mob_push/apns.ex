defmodule MobPush.APNS do
  @moduledoc """
  APNs HTTP/2 adapter for MobPush.

  Sends push notifications to iOS devices via Apple Push Notification service
  using token-based auth (p8 key) over HTTP/2. Called internally by
  `MobPush.send/3` — you can also call it directly for advanced use cases.

  ## Configuration

      config :mob_push, :apns,
        key_id:    "XXXXXXXXXX",           # 10-char Key ID from the Apple Developer portal Keys page
        team_id:   "XXXXXXXXXX",           # 10-char Team ID from Membership Details
        bundle_id: "com.example.myapp",    # must match the app's bundle ID exactly
        key_file:  "/path/to/AuthKey_XXXXXXXXXX.p8",  # path to the .p8 file on disk
        # OR: key_pem: "-----BEGIN PRIVATE KEY-----\\n..."  # PEM string (from secret manager, etc.)
        env:       :sandbox                # :sandbox | :production (default: :sandbox)

  **Sandbox vs production:** These are completely separate APNs endpoints with
  separate device token namespaces. A sandbox token sent to the production
  endpoint returns `"BadDeviceToken"`. Use `:sandbox` for Xcode/TestFlight dev
  builds and `:production` for App Store / TestFlight production builds.

  ## Payload options

  | Key                  | Type    | Description |
  |----------------------|---------|-------------|
  | `:title`             | string  | Bold title line (required) |
  | `:body`              | string  | Main text (required) |
  | `:subtitle`          | string  | Second line under the title, shown in lighter weight |
  | `:badge`             | integer | Badge count on the app icon; pass `0` to clear |
  | `:sound`             | string  | `"default"` for system sound; or a filename (no extension) bundled in the app. Files must be `.aiff`, `.wav`, or `.caf` and under 30 seconds. |
  | `:content_available` | boolean | Silent push — wakes the app in the background without showing any alert. The app has ~30 seconds of background time. |
  | `:data`              | map     | Arbitrary key-value pairs merged into the APNs root payload. Keys are stringified; values are passed through as-is (can be nested). |

  ## Authentication

  Uses ES256 JWT tokens signed with the `.p8` key. Tokens are valid for 1 hour;
  `MobPush.TokenCache` refreshes them 5 minutes early. On a 403 response, the
  token is evicted and a fresh one is fetched on the next call.

  ## Usage

      MobPush.APNS.send("device_token_hex", %{
        title:    "New message",
        subtitle: "From Alice",
        body:     "Hey, are you free tonight?",
        badge:    3,
        sound:    "default",
        data:     %{screen: "chat", thread_id: "42"}
      })
  """

  require Logger

  @sandbox_url "https://api.sandbox.push.apple.com"
  @production_url "https://api.push.apple.com"

  @doc "Send a push notification to an iOS device token."
  @spec send(device_token :: String.t(), payload :: map()) :: :ok | {:error, term()}
  def send(device_token, payload) do
    cfg = config()

    with {:ok, jwt} <- bearer_token(cfg) do
      url = "#{base_url(cfg)}/3/device/#{device_token}"
      body = build_aps(payload)

      headers = [
        {"authorization", "bearer #{jwt}"},
        {"apns-topic", cfg[:bundle_id]},
        {"apns-push-type", "alert"},
        {"content-type", "application/json"}
      ]

      req = Req.new(finch: MobPush.Finch, url: url, headers: headers, body: body)

      case Req.post(req) do
        {:ok, %{status: 200}} ->
          :ok

        {:ok, %{status: 410}} ->
          {:error, :device_token_expired}

        {:ok, %{status: 400, body: body}} ->
          reason = parse_error(body)
          {:error, {:apns_error, reason}}

        {:ok, %{status: 403}} ->
          # JWT may be stale — evict and let caller retry
          MobPush.TokenCache.evict({:apns_jwt, cfg[:key_id]})
          {:error, :auth_failed}

        {:ok, resp} ->
          {:error, {:unexpected_status, resp.status, resp.body}}

        {:error, _} = err ->
          err
      end
    end
  end

  # ── JWT bearer token ───────────────────────────────────────────────────────

  defp bearer_token(cfg) do
    key_id = cfg[:key_id]
    team_id = cfg[:team_id]

    MobPush.TokenCache.get({:apns_jwt, key_id}, fn ->
      with {:ok, pem} <- pem(cfg) do
        sign_jwt(team_id, key_id, pem)
      end
    end)
  end

  defp sign_jwt(team_id, key_id, pem) do
    now = System.system_time(:second)
    header = %{"alg" => "ES256", "kid" => key_id}
    claims = %{"iss" => team_id, "iat" => now}

    try do
      jwk = JOSE.JWK.from_pem(pem)
      {_, token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, header, claims))
      # APNs JWTs are valid for 1 hour; refresh after 50 minutes.
      {:ok, {token, now + 3000}}
    rescue
      e -> {:error, {:jwt_sign_error, Exception.message(e)}}
    end
  end

  defp pem(cfg) do
    cond do
      cfg[:key_pem] ->
        {:ok, cfg[:key_pem]}

      cfg[:key_file] ->
        case File.read(cfg[:key_file]) do
          {:ok, pem} -> {:ok, pem}
          {:error, reason} -> {:error, {:apns_key_file_unreadable, cfg[:key_file], reason}}
        end

      true ->
        {:error, :missing_apns_key_config}
    end
  end

  # ── Payload building ───────────────────────────────────────────────────────

  defp build_aps(%{title: title, body: body} = payload) do
    alert = %{"title" => title, "body" => body}
    alert = if Map.get(payload, :subtitle), do: Map.put(alert, "subtitle", payload.subtitle), else: alert
    aps = %{"alert" => alert}
    aps = if Map.get(payload, :badge), do: Map.put(aps, "badge", payload.badge), else: aps
    aps = if Map.get(payload, :sound), do: Map.put(aps, "sound", payload.sound), else: aps

    aps =
      if Map.get(payload, :content_available), do: Map.put(aps, "content-available", 1), else: aps

    root = %{"aps" => aps}

    root =
      if data = Map.get(payload, :data), do: Map.merge(root, stringify_keys(data)), else: root

    Jason.encode!(root)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp parse_error(body) when is_map(body), do: body["reason"] || "unknown"

  defp parse_error(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded["reason"] || body
      _ -> body
    end
  end

  defp parse_error(_), do: "unknown"

  defp base_url(cfg) do
    case cfg[:env] do
      :production -> @production_url
      _ -> @sandbox_url
    end
  end

  defp config do
    Application.get_env(:mob_push, :apns, [])
  end
end

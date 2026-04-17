defmodule MobPush.FCM do
  @moduledoc """
  FCM HTTP v1 adapter for MobPush.

  Sends push notifications to Android devices via Firebase Cloud Messaging
  HTTP v1 API using a Google service account for OAuth2 authentication.

  ## Configuration

      config :mob_push, :fcm,
        project_id:          "my-firebase-project",
        service_account_key: "/path/to/service-account.json"
        # OR: service_account_json: %{...}  (already-decoded map)

  The service account JSON file is downloaded from the Firebase console:
  Project Settings → Service Accounts → Generate new private key.

  ## Usage

  Called internally by `MobPush.send/3`. You can also call it directly:

      MobPush.FCM.send("device_registration_token", %{title: "Hi", body: "Hello", data: %{}})
  """

  @fcm_url     "https://fcm.googleapis.com/v1/projects"
  @token_url   "https://oauth2.googleapis.com/token"
  @scope       "https://www.googleapis.com/auth/firebase.messaging"

  @doc "Send a push notification to an Android device token."
  @spec send(device_token :: String.t(), payload :: map()) :: :ok | {:error, term()}
  def send(device_token, payload) do
    cfg = config()
    sa  = service_account(cfg)
    with {:ok, access_token} <- oauth_token(sa) do
      url  = "#{@fcm_url}/#{cfg[:project_id]}/messages:send"
      body = build_message(device_token, payload)
      req  = Req.new(
        finch:   MobPush.Finch,
        url:     url,
        headers: [
          {"authorization", "Bearer #{access_token}"},
          {"content-type",  "application/json"},
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
      "iss"   => sa["client_email"],
      "sub"   => sa["client_email"],
      "aud"   => @token_url,
      "scope" => @scope,
      "iat"   => now,
      "exp"   => now + 3600,
    }
    with {:ok, jwt} <- sign_service_account_jwt(sa, claims),
         {:ok, token, expires_in} <- exchange_jwt(jwt) do
      {:ok, {token, now + expires_in - 60}}
    end
  end

  defp sign_service_account_jwt(sa, claims) do
    try do
      jwk    = JOSE.JWK.from_pem(sa["private_key"])
      header = %{"alg" => "RS256"}
      {_, token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, header, claims))
      {:ok, token}
    rescue
      e -> {:error, {:jwt_sign_error, Exception.message(e)}}
    end
  end

  defp exchange_jwt(jwt) do
    body = URI.encode_query(%{
      "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
      "assertion"  => jwt,
    })
    req = Req.new(
      finch:   MobPush.Finch,
      url:     @token_url,
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body:    body
    )
    case Req.post(req) do
      {:ok, %{status: 200, body: resp}} ->
        token      = resp["access_token"] || resp[:access_token]
        expires_in = resp["expires_in"]   || resp[:expires_in] || 3600
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
    message = %{
      "token"        => device_token,
      "notification" => notification,
    }
    message = if data = Map.get(payload, :data) do
      Map.put(message, "data", stringify_keys(data))
    else
      message
    end
    # Android-specific options
    message = if android_opts = Map.get(payload, :android) do
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
      _              -> body
    end
  end
  defp parse_error(body), do: inspect(body)

  defp service_account(cfg) do
    cond do
      sa = cfg[:service_account_json] ->
        sa
      path = cfg[:service_account_key] ->
        path |> File.read!() |> Jason.decode!()
      true ->
        raise "mob_push :fcm config must include :service_account_key or :service_account_json"
    end
  end

  defp config do
    Application.get_env(:mob_push, :fcm, [])
  end
end

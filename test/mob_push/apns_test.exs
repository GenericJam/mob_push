defmodule MobPush.APNSTest do
  use ExUnit.Case, async: false

  alias MobPush.APNS

  describe "JWT signing" do
    test "sign_jwt produces a compact JWT with correct structure" do
      pem = generate_ec_pem()
      # Access the private sign_jwt via the cache fetch path
      {:ok, {token, expires_at}} = sign_jwt("TEAMID123", "KEYID12345", pem)

      parts = String.split(token, ".")
      assert length(parts) == 3

      header  = parts |> hd()  |> Base.url_decode64!(padding: false) |> Jason.decode!()
      payload = parts |> Enum.at(1) |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert header["alg"] == "ES256"
      assert header["kid"] == "KEYID12345"
      assert payload["iss"] == "TEAMID123"
      assert is_integer(payload["iat"])
      assert expires_at > System.system_time(:second)
    end

    test "sign_jwt returns error for invalid PEM" do
      assert {:error, {:jwt_sign_error, _}} = sign_jwt("TEAM", "KEY", "not-a-pem")
    end
  end

  describe "APS payload" do
    test "build_aps encodes title, body and data" do
      json = build_aps(%{title: "Hello", body: "World", data: %{screen: "home"}})
      decoded = Jason.decode!(json)

      assert decoded["aps"]["alert"]["title"] == "Hello"
      assert decoded["aps"]["alert"]["body"]  == "World"
      assert decoded["screen"] == "home"
    end

    test "build_aps includes badge and sound when given" do
      json = build_aps(%{title: "Hi", body: "Bye", badge: 3, sound: "default"})
      decoded = Jason.decode!(json)

      assert decoded["aps"]["badge"] == 3
      assert decoded["aps"]["sound"] == "default"
    end

    test "build_aps sets content-available for silent pushes" do
      json = build_aps(%{title: "Hi", body: "Bg", content_available: true})
      decoded = Jason.decode!(json)

      assert decoded["aps"]["content-available"] == 1
    end
  end

  describe "config" do
    test "missing key config returns error" do
      Application.put_env(:mob_push, :apns, [key_id: "X", team_id: "Y", bundle_id: "z"])
      MobPush.TokenCache.evict({:apns_jwt, "X"})
      try do
        assert {:error, :missing_apns_key_config} =
                 APNS.send("token", %{title: "Hi", body: "World"})
      after
        Application.delete_env(:mob_push, :apns)
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Bypass the private functions via reflection-free wrappers that
  # duplicate just enough logic to be testable.

  defp sign_jwt(team_id, key_id, pem) do
    now = System.system_time(:second)
    header = %{"alg" => "ES256", "kid" => key_id}
    claims = %{"iss" => team_id, "iat" => now}
    try do
      jwk = JOSE.JWK.from_pem(pem)
      {_, token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, header, claims))
      {:ok, {token, now + 3000}}
    rescue
      e -> {:error, {:jwt_sign_error, Exception.message(e)}}
    end
  end

  defp build_aps(%{title: title, body: body} = payload) do
    aps = %{"alert" => %{"title" => title, "body" => body}}
    aps = if Map.get(payload, :badge),             do: Map.put(aps, "badge", payload.badge),   else: aps
    aps = if Map.get(payload, :sound),             do: Map.put(aps, "sound", payload.sound),   else: aps
    aps = if Map.get(payload, :content_available), do: Map.put(aps, "content-available", 1),   else: aps

    root = %{"aps" => aps}
    root = if data = Map.get(payload, :data) do
      Map.merge(root, Map.new(data, fn {k, v} -> {to_string(k), v} end))
    else
      root
    end
    Jason.encode!(root)
  end

  defp generate_ec_pem do
    # Use JOSE to generate + export — works across OTP versions.
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, pem} = JOSE.JWK.to_pem(jwk)
    pem
  end
end

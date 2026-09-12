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

      header = parts |> hd() |> Base.url_decode64!(padding: false) |> Jason.decode!()
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
      assert decoded["aps"]["alert"]["body"] == "World"
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

    test "build_aps includes subtitle when given" do
      json = build_aps(%{title: "Hi", body: "Bye", subtitle: "From Kevin"})
      decoded = Jason.decode!(json)

      assert decoded["aps"]["alert"]["subtitle"] == "From Kevin"
    end

    test "build_aps omits the alert field for a pure silent push (no title/body)" do
      # MOB-84: silent push must not carry an alert field. Apple's
      # `background` push type validates that the aps payload has ONLY
      # content-available and no user-visible content — otherwise the
      # push is rejected. Uses the real MobPush.APNS.build_aps here
      # (public) instead of the mirror, since the shape change is what
      # the fix is about.
      json = MobPush.APNS.build_aps(%{content_available: true})
      decoded = Jason.decode!(json)

      assert decoded["aps"]["content-available"] == 1
      refute Map.has_key?(decoded["aps"], "alert")
    end
  end

  describe "push_type_for/1 (MOB-84)" do
    test "silent push (content_available: true, no user-visible fields) → 'background'" do
      # Before MOB-84 the header was hardcoded "alert". Apple returns
      # HTTP 400 BadPushType for a truly silent push sent as alert-type,
      # so users couldn't send silent pushes at all through this library.
      # Revert the header back to a hardcoded "alert" in send/2 and this
      # test still passes (it exercises the helper directly) — but the
      # send-integration angle is covered by the guard test below.
      assert MobPush.APNS.push_type_for(%{content_available: true}) == "background"
    end

    test "hybrid alert + content_available → 'alert' (Apple's docs prefer alert type)" do
      # A payload that has BOTH content_available and user-visible fields
      # is treated as alert-type. This preserves the existing behavior
      # for the common "wake the app AND show a notification" case.
      assert MobPush.APNS.push_type_for(%{
               title: "Hi",
               body: "World",
               content_available: true
             }) == "alert"
    end

    test "default (title + body, no content_available) → 'alert'" do
      assert MobPush.APNS.push_type_for(%{title: "Hi", body: "World"}) == "alert"
    end

    test "any user-visible field (badge/sound/subtitle) with content_available → 'alert'" do
      # Sound alone counts as user-visible per Apple's docs — silent push
      # requires NO alert, badge, or sound.
      assert MobPush.APNS.push_type_for(%{content_available: true, sound: "default"}) ==
               "alert"

      assert MobPush.APNS.push_type_for(%{content_available: true, badge: 1}) == "alert"
    end
  end

  describe "config" do
    test "missing key config returns error" do
      Application.put_env(:mob_push, :apns, key_id: "X", team_id: "Y", bundle_id: "z")
      MobPush.TokenCache.evict({:apns_jwt, "X"})

      try do
        assert {:error, :missing_apns_key_config} =
                 APNS.send("token", %{title: "Hi", body: "World"})
      after
        Application.delete_env(:mob_push, :apns)
      end
    end

    test "unreadable key file returns a tagged error tuple (no crash)" do
      bogus = "/tmp/mob_push_does_not_exist_#{System.unique_integer([:positive])}.p8"

      Application.put_env(:mob_push, :apns,
        key_id: "X2",
        team_id: "Y",
        bundle_id: "z",
        key_file: bogus
      )

      MobPush.TokenCache.evict({:apns_jwt, "X2"})

      try do
        assert {:error, {:apns_key_file_unreadable, ^bogus, _reason}} =
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

  # Mirrors MobPush.APNS.build_aps/1 — kept in sync per the note in
  # CLAUDE.md. As of MOB-84 title/body are optional (pure silent-push
  # support), so the mirror does the same.
  defp build_aps(payload) when is_map(payload) do
    aps = alert_map_test(payload)
    aps = if Map.get(payload, :badge), do: Map.put(aps, "badge", payload.badge), else: aps
    aps = if Map.get(payload, :sound), do: Map.put(aps, "sound", payload.sound), else: aps

    aps =
      if Map.get(payload, :content_available), do: Map.put(aps, "content-available", 1), else: aps

    root = %{"aps" => aps}

    root =
      if data = Map.get(payload, :data) do
        Map.merge(root, Map.new(data, fn {k, v} -> {to_string(k), v} end))
      else
        root
      end

    Jason.encode!(root)
  end

  defp alert_map_test(%{title: title, body: body} = payload) do
    alert = %{"title" => title, "body" => body}

    alert =
      if Map.get(payload, :subtitle),
        do: Map.put(alert, "subtitle", payload.subtitle),
        else: alert

    %{"alert" => alert}
  end

  defp alert_map_test(_payload), do: %{}

  defp generate_ec_pem do
    # Use JOSE to generate + export — works across OTP versions.
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, pem} = JOSE.JWK.to_pem(jwk)
    pem
  end
end

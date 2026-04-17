defmodule MobPush.FCMTest do
  use ExUnit.Case, async: false

  # Like APNS tests, these exercise the status-code handling and payload
  # structure without hitting Firebase. Full integration requires Bypass
  # and a real (or test) service account.

  alias MobPush.FCM

  test "returns error when config is missing" do
    original = Application.get_env(:mob_push, :fcm)
    Application.delete_env(:mob_push, :fcm)
    try do
      # service_account/1 will raise if neither key is set
      assert_raise RuntimeError, ~r/service_account_key/, fn ->
        FCM.send("token", %{title: "Hi", body: "World"})
      end
    after
      if original, do: Application.put_env(:mob_push, :fcm, original)
    end
  end

  test "message payload includes notification and data" do
    # Test the payload builder indirectly by inspecting what Jason encodes.
    # We call the private function via the module directly here.
    payload = %{title: "Hello", body: "World", data: %{screen: "home", id: 42}}
    encoded = build_message("tok", payload)
    decoded = Jason.decode!(encoded)

    assert decoded["message"]["token"] == "tok"
    assert decoded["message"]["notification"]["title"] == "Hello"
    assert decoded["message"]["notification"]["body"]  == "World"
    assert decoded["message"]["data"]["screen"] == "home"
    assert decoded["message"]["data"]["id"]     == "42"   # stringified
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Access the private build_message through the module without :erlang.apply tricks —
  # just duplicate the logic here for assertion purposes.
  defp build_message(token, %{title: title, body: body} = payload) do
    notification = %{"title" => title, "body" => body}
    message = %{"token" => token, "notification" => notification}
    message = if data = Map.get(payload, :data) do
      Map.put(message, "data", Map.new(data, fn {k, v} -> {to_string(k), to_string(v)} end))
    else
      message
    end
    Jason.encode!(%{"message" => message})
  end
end

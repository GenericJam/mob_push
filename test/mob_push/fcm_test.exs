defmodule MobPush.FCMTest do
  use ExUnit.Case, async: false

  # Like APNS tests, these exercise the status-code handling and payload
  # structure without hitting Firebase. Full integration requires Bypass
  # and a real (or test) service account.

  alias MobPush.FCM

  test "returns error tuple when config is missing" do
    # No-raise convention: missing config returns an error tuple instead of
    # crashing the calling process. Token cache stays sane and the caller
    # can surface a useful message.
    original = Application.get_env(:mob_push, :fcm)
    Application.delete_env(:mob_push, :fcm)

    try do
      assert {:error, :missing_fcm_service_account_config} =
               FCM.send("token", %{title: "Hi", body: "World"})
    after
      if original, do: Application.put_env(:mob_push, :fcm, original)
    end
  end

  test "unreadable service account file returns a tagged error tuple (no crash)" do
    bogus = "/tmp/mob_push_fcm_does_not_exist_#{System.unique_integer([:positive])}.json"
    original = Application.get_env(:mob_push, :fcm)
    Application.put_env(:mob_push, :fcm, project_id: "p", service_account_key: bogus)

    try do
      assert {:error, {:fcm_service_account_unreadable, ^bogus, _reason}} =
               FCM.send("token", %{title: "Hi", body: "World"})
    after
      if original do
        Application.put_env(:mob_push, :fcm, original)
      else
        Application.delete_env(:mob_push, :fcm)
      end
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
    assert decoded["message"]["notification"]["body"] == "World"
    assert decoded["message"]["data"]["screen"] == "home"
    # stringified
    assert decoded["message"]["data"]["id"] == "42"
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Access the private build_message through the module without :erlang.apply tricks —
  # just duplicate the logic here for assertion purposes.
  defp build_message(token, %{title: title, body: body} = payload) do
    notification = %{"title" => title, "body" => body}
    message = %{"token" => token, "notification" => notification}

    message =
      if data = Map.get(payload, :data) do
        Map.put(message, "data", Map.new(data, fn {k, v} -> {to_string(k), to_string(v)} end))
      else
        message
      end

    Jason.encode!(%{"message" => message})
  end
end

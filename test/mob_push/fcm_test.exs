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
    payload = %{title: "Hello", body: "World", data: %{screen: "home", id: 42}}
    encoded = FCM.build_message("tok", payload)
    decoded = Jason.decode!(encoded)

    assert decoded["message"]["token"] == "tok"
    assert decoded["message"]["notification"]["title"] == "Hello"
    assert decoded["message"]["notification"]["body"] == "World"
    assert decoded["message"]["data"]["screen"] == "home"
    # stringified
    assert decoded["message"]["data"]["id"] == "42"

    assert Jason.decode!(decoded["message"]["data"]["mob_notification_json"]) == %{
             "title" => "Hello",
             "body" => "World",
             "source" => "push",
             "data" => %{"screen" => "home", "id" => "42"}
           }
  end

  test "message payload includes the delivery envelope without custom data" do
    decoded =
      FCM.build_message("tok", %{title: "Hello", body: "World"})
      |> Jason.decode!()

    assert %{"mob_notification_json" => envelope_json} = decoded["message"]["data"]
    assert map_size(decoded["message"]["data"]) == 1

    assert Jason.decode!(envelope_json) == %{
             "title" => "Hello",
             "body" => "World",
             "source" => "push",
             "data" => %{}
           }
  end

  describe "silent (data-only) push — content_available: true + no visible fields" do
    # Regression for the "mob_wake silent-wake broken end-to-end on Android"
    # bug. An FCM message with a `notification` block is handled by the OS
    # tray when the app is backgrounded — MobWakeFcmService.onMessageReceived
    # never fires. Data-only invokes the service in every state. Mirrors
    # APNs's MOB-84 push_type_for/1 detection: silent = content_available
    # AND no user-visible fields.

    test "omits notification block entirely (data-only wire shape)" do
      decoded =
        FCM.build_message("tok", %{
          content_available: true,
          data: %{"mob_wake_id" => "sj_bump"}
        })
        |> Jason.decode!()

      refute Map.has_key?(decoded["message"], "notification")
      assert decoded["message"]["data"]["mob_wake_id"] == "sj_bump"
      # No mob_notification_json injected either — that's for the tray
      # reconstruction path, which silent pushes don't take.
      refute Map.has_key?(decoded["message"]["data"], "mob_notification_json")
    end

    test "adds priority=high so backgrounded/Doze devices still wake" do
      decoded =
        FCM.build_message("tok", %{
          content_available: true,
          data: %{"mob_wake_id" => "sj_bump"}
        })
        |> Jason.decode!()

      assert decoded["message"]["android"]["priority"] == "high"
    end

    test "caller :android opts override the default priority (opt-in)" do
      # An app that explicitly wants a "normal"-priority silent push (rare —
      # analytics ping without waking Doze, say) can override the default.
      decoded =
        FCM.build_message("tok", %{
          content_available: true,
          data: %{"mob_wake_id" => "sj_bump"},
          android: %{"priority" => "normal"}
        })
        |> Jason.decode!()

      assert decoded["message"]["android"]["priority"] == "normal"
    end

    test "content_available with a visible field (title) still emits notification (hybrid, not silent)" do
      # A caller that passes title AND content_available: true wants a
      # visible-AND-wake push. Not "silent". Backwards-compat with the
      # historical shape.
      decoded =
        FCM.build_message("tok", %{
          title: "Hi",
          body: "There",
          content_available: true,
          data: %{"mob_wake_id" => "sj_bump"}
        })
        |> Jason.decode!()

      assert decoded["message"]["notification"]["title"] == "Hi"
      assert decoded["message"]["data"]["mob_wake_id"] == "sj_bump"
    end

    test "no content_available AND no title raises ArgumentError with actionable guidance" do
      # Detects the misuse: caller forgot title/body but ALSO didn't set the
      # silent flag. Clear message rather than a mysterious KeyError.
      assert_raise ArgumentError, ~r/requires :title and :body|content_available: true/, fn ->
        FCM.build_message("tok", %{data: %{"mob_wake_id" => "sj_bump"}})
      end
    end
  end
end

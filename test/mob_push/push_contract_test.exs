defmodule MobPush.PushContractTest do
  use ExUnit.Case, async: true

  # The wire contract with the device side (the mob_notify plugin). The fixture
  # is VENDORED BYTE-IDENTICALLY in both repos — see its header. This suite
  # asserts the SERVER half: our pure payload builders produce exactly the
  # shapes the fixture documents. mob_notify's suite asserts the device half.
  @contract Code.eval_file(Path.join([__DIR__, "..", "fixtures", "push_contract.exs"]))
            |> elem(0)

  test "APNs: build_aps/1 encodes the documented payload (data merged at root)" do
    decoded = MobPush.APNS.build_aps(@contract.notif) |> Jason.decode!()
    assert decoded == @contract.apns_decoded
  end

  test "FCM: build_message/2 encodes the documented v1 message" do
    {:push_token, :android, token} =
      Enum.find(@contract.push_token_messages, &match?({:push_token, :android, _}, &1))

    %{"message" => message} =
      MobPush.FCM.build_message(token, @contract.notif) |> Jason.decode!()

    {envelope_json, sans_envelope} = pop_in(message, ["data", "mob_notification_json"])

    assert sans_envelope == @contract.fcm_message_sans_envelope

    # The envelope is what MobFirebaseService / the tap-reconstruction path
    # consume on-device — compare DECODED (JSON key order isn't contract).
    assert Jason.decode!(envelope_json) == @contract.mob_notification_decoded
  end

  test "the fixture still records the open iOS source-drift (see mob_notify EXTRACTION.md)" do
    assert @contract.known_drift == :ios_delegate_hardcodes_local_source
  end
end

# Push wire contract between mob_notify (device) and mob_push (server).
#
# VENDORED BYTE-IDENTICALLY in BOTH repos:
#   mob_notify/test/fixtures/push_contract.exs
#   mob_push/test/fixtures/push_contract.exs
# Update both copies together — each repo's suite asserts its own half against
# this data, so a one-sided edit makes the other side's promise silently stale.
%{
  # ── Input: what a server passes to MobPush.APNS.send/2 / MobPush.FCM.send/2 ──
  notif: %{
    title: "New message",
    subtitle: "in #general",
    body: "Alice: Hey, are you free tonight?",
    badge: 3,
    sound: "default",
    data: %{screen: "chat", thread_id: "42"}
  },

  # ── Registration: the device messages MobNotify.register_push/1 produces ──
  # (mob core's mob_send_push_token / the FCM token thunk deliver these)
  push_token_messages: [
    {:push_token, :ios, "a1b2c3d4e5f6"},
    {:push_token, :android, "fcm-example-token"}
  ],

  # ── APNs: decoded JSON body MobPush.APNS builds (build_aps/1) ──
  # Custom :data keys are stringified and merged at the ROOT (Apple convention),
  # not nested under "data".
  apns_decoded: %{
    "aps" => %{
      "alert" => %{
        "title" => "New message",
        "subtitle" => "in #general",
        "body" => "Alice: Hey, are you free tonight?"
      },
      "badge" => 3,
      "sound" => "default"
    },
    "screen" => "chat",
    "thread_id" => "42"
  },

  # ── FCM: the v1 message map MobPush.FCM builds (build_message/2) ──
  # data values are stringified; mob_notification_json is the envelope
  # MobFirebaseService (host app) and MainActivity tap-reconstruction consume.
  # The real field is a JSON-ENCODED STRING of mob_notification_decoded below —
  # compare it decoded (JSON key order is not part of the contract).
  fcm_message_sans_envelope: %{
    "token" => "fcm-example-token",
    "notification" => %{
      "title" => "New message",
      "body" => "Alice: Hey, are you free tonight?"
    },
    "data" => %{
      "screen" => "chat",
      "thread_id" => "42"
    }
  },
  mob_notification_decoded: %{
    "title" => "New message",
    "body" => "Alice: Hey, are you free tonight?",
    "source" => "push",
    "data" => %{"screen" => "chat", "thread_id" => "42"}
  },

  # ── Device delivery: the handle_info shapes the device app receives ──
  # Android push (via mob_notification_json): full envelope.
  device_push_notification:
    {:notification,
     %{
       title: "New message",
       body: "Alice: Hey, are you free tonight?",
       source: :push,
       data: %{"screen" => "chat", "thread_id" => "42"}
     }},
  # iOS local (UNUserNotificationCenter delegate, mob_nif.m deliverNotification):
  # %{id, source, data} — NO title/body.
  device_local_notification:
    {:notification, %{id: "reminder_1", source: :local, data: %{screen: "reminders"}}},

  # ── KNOWN DRIFT (recorded 2026-06-11, to resolve in the mob_notify Stage-1b/2
  # native pass, NOT silently): mob core's iOS delegate (ios/mob_nif.m:3184,3192)
  # hardcodes source "local" for BOTH willPresent and didReceive paths — a tapped
  # REMOTE push that routes through it would arrive as source: :local without
  # title/body, while Android's mob_notification_json path delivers the full
  # source: :push envelope above. The Mob.Notify docs promise the Android shape.
  known_drift: :ios_delegate_hardcodes_local_source
}

# Changelog

All notable changes to **mob_push** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.2.2] - 2026-10-02

### Fixed

- **The first push after boot no longer fails with `pool_not_available`**
  (MOB-318). Until its HTTP/2 connection to Apple is up, Finch 0.22/0.23
  reject requests without sending them (`%Req.HTTPError{reason:
  :pool_not_available}`; older Finch says `:disconnected`), and the POST
  was not retried, so a wake sent right after boot was lost. APNs and FCM
  requests now retry errors that guarantee the server did not process the
  request: Finch never sent it (`pool_not_available`, `disconnected`), the
  connection stopped taking writes before the request was fully written
  (`read_only`), or the server's GOAWAY or REFUSED_STREAM rejected it
  unprocessed (`unprocessed`, `{:server_closed_request, :refused_stream}`).
  Backoff is short, and no retry starts later than 1.5 s after the first
  attempt, so a caller waits at most that plus one attempt. Timeouts,
  connections closed mid-request and every HTTP response are still
  returned at once, since the push may already have been delivered.

- **APNs `apns-push-type` header now branches on payload shape** (MOB-84).
  The header was hardcoded to `"alert"`, so a truly silent push
  (`content_available: true` with no user-visible fields) was rejected
  by Apple with HTTP 400 `BadPushType`. The new
  `MobPush.APNS.push_type_for/1` returns `"background"` for a pure
  silent push and `"alert"` otherwise (including hybrid
  alert+content_available payloads, which Apple treats as alert-type
  per docs).

- **FCM silent pushes are now data-only, so they wake a backgrounded
  Android app.** A payload with `content_available: true` and no
  user-visible fields (title/body/subtitle/sound/badge) used to carry a
  `notification` block; Android then handled it in the system tray and
  never called `FirebaseMessagingService.onMessageReceived`, so mob_wake
  handlers didn't fire. The silent message now has no `notification`
  block and no `mob_notification_json`, and defaults
  `android.priority` to `"high"` so Doze doesn't hold it (a caller's
  `:android` options still win). Pushes with a title and
  `content_available: true` are unchanged.

### Changed

- **`MobPush.APNS.build_aps/1` no longer requires `:title` and `:body`.**
  A payload with just `content_available: true` (or with `:data` alone)
  now produces a valid `aps` map without the `"alert"` key — matching
  Apple's requirement that `background` push type carries no alert.
  Existing alert payloads are unchanged (title/body still populate
  `aps.alert` when present).

- **An FCM payload that is neither silent nor has a string `:title` and
  `:body` raises `ArgumentError`** naming both ways to fix it (add title
  and body, or set `content_available: true` for a silent push), instead
  of a `KeyError`.

- **`mix mob_push.setup.fcm` requires your own Google OAuth client**
  (MOB-85). mob_push no longer ships a placeholder client. Create a
  "Desktop app" OAuth 2.0 client in Google Cloud Credentials and export
  `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET` before running
  the wizard; without them it stops with instructions. Alternatively, set
  up FCM manually with an existing Firebase service-account key.

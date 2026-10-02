# Changelog

All notable changes to **mob_push** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed

- **The first push after boot no longer fails with `pool_not_available`**
  (MOB-318). Until its HTTP/2 connection to Apple is up, Finch 0.22/0.23
  reject requests without sending them (`%Req.HTTPError{reason:
  :pool_not_available}`; older Finch says `:disconnected`), and the POST
  was not retried, so a wake sent right after boot was lost. APNs and FCM
  requests now retry errors that guarantee the server did not process the
  request: Finch never sent it (`pool_not_available`, `disconnected`), or
  the server's GOAWAY or REFUSED_STREAM rejected it unprocessed
  (`unprocessed`, `{:server_closed_request, :refused_stream}`). Backoff
  is short, and no retry starts later than 1.5 s after the first attempt,
  so a caller waits at most that plus one attempt. Timeouts, connections
  closed mid-request and every HTTP response are still returned at once,
  since the push may already have been delivered.

- **APNs `apns-push-type` header now branches on payload shape** (MOB-84).
  The header was hardcoded to `"alert"`, so a truly silent push
  (`content_available: true` with no user-visible fields) was rejected
  by Apple with HTTP 400 `BadPushType`. The new
  `MobPush.APNS.push_type_for/1` returns `"background"` for a pure
  silent push and `"alert"` otherwise (including hybrid
  alert+content_available payloads, which Apple treats as alert-type
  per docs).

### Changed

- **`MobPush.APNS.build_aps/1` no longer requires `:title` and `:body`.**
  A payload with just `content_available: true` (or with `:data` alone)
  now produces a valid `aps` map without the `"alert"` key — matching
  Apple's requirement that `background` push type carries no alert.
  Existing alert payloads are unchanged (title/body still populate
  `aps.alert` when present).

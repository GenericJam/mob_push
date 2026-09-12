# Changelog

All notable changes to **mob_push** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed

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

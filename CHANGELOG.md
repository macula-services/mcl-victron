# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Changed

- **mcl_om `~> 0.28`, which requires macula 12.2.** Under macula 12.2 an older
  mcl_om lets a failed publish announcement kill the publishing process. The
  service answers `mcl-victron/info` with no code of its own (which also makes
  it count as online on the realm's Providers desk); `mcl_victron_info_tests`
  round-trips it through macula's codec and fails unless it reports mcl_om 0.28
  with macula 12.2.
- **The team image pair.** The image builds in `macula-ci-otp` and runs on
  `macula-pq-runtime`, both pinned by dated tag and digest (20260923-1444),
  instead of the hexpm Alpine builder and a floating `alpine:3.22` runtime;
  lint runs on the same build image. The runtime image carries every library
  the old apk line installed. The image is labelled with the commit it was
  built from.

## [0.1.0]

The macula 12 port of hecate-victron, on mcl_om.

### Changed

- **mcl_om 0.27.** Its boot claim carries `MCL_SERVICE_NAME` and `MCL_BOX`,
  which the realm's operator needs to see to admit it. The compose file sets
  both, with `MCL_BOX` required. 0.27 no longer brings rocksdb, so the rocksdb
  codec packages are gone from the builder, the runtime image and CI.
- **One fact topic.** Readings were published each on its own
  `mri:device:<realm>/victron/<portal>/<service>/<instance>/<path>` string,
  which is not a macula 12 topic and put identifiers in topic names. They are
  now `reading_recorded_v1` on `<realm>/mcl-victron/victron/energy/`, with the
  device and the path in the payload.
- **Text is text.** Every string in the fact leaves as CBOR text, so non-BEAM
  consumers see strings rather than hex. Booleans leave as 1/0.
- **One application.** The ingest desks lived in a second OTP application that
  started before `mcl_om:boot/1` had opened the store they write to. They now
  run under `mcl_victron_sup`, which starts after the store is open.
- **Commands go through `evoq_command_router`.** `evoq_dispatcher`, which the
  handler called, is not in evoq 1.24.

### Fixed

- **Readings are recorded at all.** The stream id `victron_device-<portal>` is
  not a reckon-db 5 stream id (`[a-z]{1,32}-[a-f0-9]{32}`), so every append
  was refused. The stream is now `victron-` and 128 bits of sha256(portal id),
  and the device state takes its portal id from the events.
- **The GX is not asked to republish everything every 30 s.** The keepalive
  was always empty, and an empty keepalive makes dbus-flashmq republish every
  topic it has. Each republish re-recorded every value of the device, faster
  than the store can write. Only the first keepalive per portal on a
  connection is empty now; the rest carry `suppress-republish`.
- **Facts carry the reading.** evoq hands a handler the event envelope, and
  the emitter read its fields off the envelope, so every fact would have gone
  out with null fields. It reads `data`. A test follows a reading from
  dispatch through the real store subscription to the publish.
- **A failed publish cannot crash the emitter.** Publishes run in monitored
  workers, not linked `macula_publisher`s. A pool that died mid-call used to
  kill the emitter, and ten of those stopped the node. Each publish is also
  one frame now, where the publisher sent two announcements besides.
- **Health means readings can arrive.** It is degraded when the service is not
  connected to the broker or has heard nothing for 1.5 keepalives, and a
  silent broker is dialled again instead of waiting out TCP.
- **Aggregates snapshot**, so a device's ever-growing stream is not replayed
  from the start when its aggregate starts.
- **Every instance has its own MQTT client id**, and it disconnects cleanly.
- **A restart does not republish history.** The emitter declares
  `replay_policy() -> skip` (evoq 1.24).
- **Readings the mesh did not take are counted and reported**, once a minute,
  instead of vanishing: refused, crashed, no mesh, or over the in-flight bound. The README no longer says they queue and drain: they
  never did, and live telemetry should not.
- **The device state counts every reading.** `apply_event` matched a binary
  `event_type` that events applied after `execute` never carry.
- **The image builds.** Its Containerfile copied a `rebar.lock` the repository
  does not have and ran on OTP 27.

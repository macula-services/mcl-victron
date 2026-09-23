# mcl-victron

**Victron energy telemetry on the mesh.** mcl-victron watches a Victron GX
device (Cerbo, Venus GX) through its `dbus-flashmq` MQTT broker on the LAN.
It records every reading in its own [reckon-db](https://hex.pm/packages/reckon_db)
store and publishes each one live on the
[macula](https://github.com/macula-io/macula) mesh.

It runs on macula 12 through [mcl_om](https://hex.pm/packages/mcl_om), and
every reading it publishes is signed post-quantum.

## How a reading travels

1. `receive_victron_mqtt` speaks MQTT 3.1.1 to the broker (`mqtt_packet`, QoS
   0, about 200 lines, no library). It subscribes to `N/+/+/+/#` and sends
   both keepalives a GX needs: `PINGREQ` for the broker session, and
   `R/<portal>/keepalive` so the GX keeps publishing values. The first
   keepalive for a portal on each connection asks the GX to republish every
   topic, which is how the current values arrive. Every keepalive after that
   carries `suppress-republish`, so from then on the GX sends only what
   changes. A broker that stops answering for 1.5 keepalives is left and
   dialled again.
2. Each notification becomes a `record_victron_reading_v1` command, which
   evoq dispatches to the `victron_device` aggregate. The aggregate has one
   stream per GX device in `mcl_victron_store`: `victron-` followed by the first
   128 bits of the sha256 of its portal id, in hex.
3. The recorded `victron_reading_recorded_v1` event reaches the emitter,
   which publishes it as a `reading_recorded_v1` fact. Each publish runs in a
   worker the emitter monitors, with at most 64 in flight at once.

A zero-byte payload, a non-JSON payload and `{"value": null}` are absences,
not measurements, so they are not recorded.

## Mesh surface

One fact, on `<realm>/mcl-victron/victron/energy/reading_recorded_v1`:

| Field | What |
|---|---|
| `portal_id` | the GX device's VRM portal id |
| `service` | `battery`, `solarcharger`, `vebus`, `grid`, `system`, ... |
| `instance` | the device instance, as text |
| `dbus_path` | the D-Bus path under the service, e.g. `Dc/0/Voltage` |
| `value` | what the GX reported: a float, an integer, text, or a list or map of those. Booleans travel as 1/0 |
| `observed_at` | epoch ms, when this service received it |

The device and the path are in the payload, not in the topic. A consumer
subscribes once and filters.

There are no procedures.

## Live, not queued

The store is the durable record, and ingest never waits for the mesh. A
reading the mesh does not take is dropped from publishing and kept in the
store. Readings published after an outage would reach consumers as if they
were current, so they are not replayed. A restart's replay of the store's
history is skipped for the same reason. The emitter counts the readings it
could not publish and logs the count at most once a minute.

## Build and test

```sh
scripts/ci-gate.sh                 # lint, eunit, dialyzer in the CI image, as root
FRESH=1 scripts/ci-gate.sh         # the same, with no cached _build: what CI sees
rebar3 as prod release
```

`record_victron_reading_tests` dispatches readings against a real reckon-db
store, opened the way `mcl_om:boot/1` opens it. The same test follows each
reading through the real store subscription and the emitter to the publish.
`receive_victron_mqtt_tests` runs the receiver against a fake broker on a local
socket.

## Configuration

| Variable | Default | What |
|---|---|---|
| `MCL_REALM` | (required) | the realm tag, 64 hex |
| `MCL_REALM_NAME` | (required) | the realm name the topic carries; its sha256 must be `MCL_REALM` |
| `MCL_REALM_KEY` | (required) | the realm's public signing key, hex |
| `MACULA_STATION_SEEDS` | (required) | `host[:port],...` |
| `MACULA_STATION_NODE_IDS` | (required) | the seeds' node ids, 64 hex each, in the same order |
| `VICTRON_MQTT_HOST` | (required) | the GX device's LAN address |
| `VICTRON_MQTT_PORT` | `1883` | dbus-flashmq's port |
| `VICTRON_MQTT_KEEPALIVE_SEC` | `30` | seconds between keepalives |
| `MCL_DATA_DIR` | `/data` | the reckon-db store |
| `MCL_HEALTH_PORT` | `8483` | `/health` |
| `MCL_NODE_NAME`, `MCL_NODE_HOST`, `MCL_COOKIE` | `mcl_victron`, `127.0.0.1`, `mcl_victron` | Erlang distribution |

The node identity is kept at `/etc/mcl/secrets/identity.key` and must be on a
persistent volume. The service must share a LAN with the GX.
`deploy/docker-compose.yml` runs it with both volumes in place.

`/health` reports `degraded` when the service is not connected to the GX's
broker, or when the broker has been silent for more than 1.5 keepalives.

## License

Apache-2.0

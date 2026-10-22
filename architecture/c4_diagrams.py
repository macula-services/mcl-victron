"""Generate mcl-victron's two C4 diagrams into assets/.

Run:  python3 architecture/c4_diagrams.py

  c4-context.svg     Level 1: what the service talks to
  c4-components.svg  Level 2: what it is made of

Drawn from the code, never from a template: the callbacks in
mcl_victron_service.erl, the receiver in receive_victron_mqtt.erl, the command
and the aggregate, the emitter in on_victron_reading_recorded_to_mesh.erl, the
dependencies in rebar.config, the port and volumes in the Containerfile and
deploy/docker-compose.yml. When one of those changes, the diagram changes in
the same commit.

Colours are plain classes with a prefers-color-scheme: dark block, no CSS custom
properties (rsvg-convert renders those black), so the SVGs render the same on
GitHub, in IDE previews and through rsvg-convert. After a change, render each
(rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png) and look at it; keep
architecture/README.md's tables in step.
"""
import os
from xml.sax.saxutils import escape

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

SANS = '"Atkinson Hyperlegible", "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif'
MONO = '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace'

# Element kinds, each (light fill, light stroke, dark fill, dark stroke).
KINDS = {
    "b-sys": ("#F5E9CC", "#A56F0A", "#3A2E13", "#E3AA3C"),   # in scope
    "b-per": ("#E3EBF2", "#3B5B7A", "#1D2A36", "#8EB4D8"),   # person
    "b-mac": ("#E6E4EE", "#5E5A78", "#26243A", "#A9A4C8"),   # Macula infrastructure
    "b-ext": ("#ECEFED", "#8A9791", "#1C2421", "#7D8B85"),   # external system
    "b-cmp": ("#FFFFFF", "#8A9791", "#171F1C", "#7D8B85"),   # component or container
}

STYLE = f"""<style>
.t-name {{ font-family: {SANS}; font-size: 15px; font-weight: 700; }}
.t-desc {{ font-family: {SANS}; font-size: 12.5px; }}
.t-rel {{ font-family: {SANS}; font-size: 11.5px; paint-order: stroke; stroke-width: 4px; stroke-linejoin: round; }}
.t-code {{ font-family: {MONO}; font-size: 13px; font-weight: 600; }}
.t-type {{ font-family: {MONO}; font-size: 11.5px; }}
.t-bound {{ font-family: {MONO}; font-size: 12px; font-weight: 600; }}
.t-leg {{ font-family: {SANS}; font-size: 12px; }}
.edge {{ fill: none; stroke-width: 1.25; }}
.edge-later {{ fill: none; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bg {{ fill: #FFFFFF; }}
""" + "".join(f".{k} {{ fill: {v[0]}; stroke: {v[1]}; stroke-width: {2 if k == 'b-sys' else 1.25}; }}\n" for k, v in KINDS.items()) + """\
.b-later { fill: none; stroke: #8A9791; stroke-width: 1.25; stroke-dasharray: 5 4; }
.bound { fill: none; stroke: #B3BDB8; stroke-width: 1; }
.head { fill: #3B5B7A; }
.t-name, .t-code { fill: #16201D; }
.t-type, .t-bound, .t-leg { fill: #66736E; }
.t-desc { fill: #34413C; }
.t-rel { fill: #66736E; stroke: #FFFFFF; }
.edge, .edge-later { stroke: #8A9791; }
.arrowhead { fill: #8A9791; }
@media (prefers-color-scheme: dark) {
.bg { fill: #171F1C; }
""" + "".join(f".{k} {{ fill: {v[2]}; stroke: {v[3]}; }}\n" for k, v in KINDS.items()) + """\
.b-later { stroke: #7D8B85; }
.bound { stroke: #4A5752; }
.head { fill: #8EB4D8; }
.t-name, .t-code { fill: #E6ECE9; }
.t-type, .t-bound, .t-leg { fill: #93A09A; }
.t-desc { fill: #C3CDC8; }
.t-rel { fill: #93A09A; stroke: #171F1C; }
.edge, .edge-later { stroke: #7D8B85; }
.arrowhead { fill: #7D8B85; }
}
</style>"""

DEFS = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        'orient="auto-start-reverse"><path class="arrowhead" d="M0 0L10 5L0 10z"/></marker></defs>')

LEGEND = [("b-sys", "In scope"), ("b-per", "Person"), ("b-mac", "Macula infrastructure"),
          ("b-ext", "External system"), ("b-cmp", "Container or component")]
BOUNDARY = ("bound", "Boundary")


class Diagram:
    def __init__(self, name, title, w, h):
        self.name, self.title, self.w, self.h, self.parts = name, title, w, h, []

    def text(self, cls, x, y, s, anchor=None, rotate=None):
        a = f' text-anchor="{anchor}"' if anchor else ""
        r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}"{a}{r}>{escape(s)}</text>')

    def box(self, cls, x, y, w, h, name, kind, desc, person=False, code=False):
        # A box that is too small for its own words renders as text on top of the
        # next box, which no test would catch and a reader would read as the
        # diagram saying something it does not. Fail here instead.
        need = 70 + 16 * max(len(desc) - 1, 0) + 18
        if h < need:
            raise ValueError(f"{self.name}: {name} needs height {need}, has {h}")
        for line in desc:
            if 16 + 6.2 * len(line) > w - 16:
                raise ValueError(f"{self.name}: {name}: '{line}' is wider than {w - 32}px")
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')
        tx = x + 16
        if person:
            self.parts.append(f'<circle class="head" cx="{x + 26}" cy="{y + 24}" r="9"/>')
            tx = x + 44
        self.text("t-code" if code else "t-name", tx, y + 28, name)
        self.text("t-type", tx, y + 46, kind)
        for i, line in enumerate(desc):
            self.text("t-desc", x + 16, y + 70 + 16 * i, line)

    def bound(self, x, y, w, h, label):
        self.parts.append(f'<rect class="bound" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')
        self.text("t-bound", x + 16, y + 22, label)

    def edge(self, d, later=False):
        self.parts.append(f'<path class="{"edge-later" if later else "edge"}" d="{d}" marker-end="url(#a)"/>')

    def legend(self, y, boundary=True):
        x = 24
        for cls, label in LEGEND + ([BOUNDARY] if boundary else []):
            self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="22" height="14" rx="3"/>')
            self.text("t-leg", x + 30, y + 12, label)
            x += 34 + 6.6 * len(label)

    def write(self):
        svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" role="img" '
               f'aria-label="{escape(self.title)}">', f"<title>{escape(self.title)}</title>", STYLE, DEFS,
               f'<rect class="bg" x="0" y="0" width="{self.w}" height="{self.h}"/>'] + self.parts + ["</svg>", ""]
        with open(os.path.join(OUT, self.name), "w") as f:
            f.write("\n".join(svg))


def context():
    d = Diagram("c4-context.svg", "mcl-victron system context", 1100, 780)
    d.box("b-per", 40, 30, 320, 120, "Service operator", "[Person]",
          ["Runs the box, sets MCL_BOX, the realm", "and station variables, and points the",
           "service at the GX's LAN address"], person=True)
    d.box("b-ext", 740, 30, 320, 136, "Consumers of the readings", "[External system]",
          ["Subscribe to one fact and filter it by", "portal, service and D-Bus path: the",
           "device and the path are in the payload,", "not in the topic name."])
    d.box("b-sys", 390, 220, 320, 152, "mcl-victron", "[mcl_om mesh service, own box]",
          ["Watches one GX device's dbus-flashmq", "broker on the LAN, records every",
           "reading in its own reckon-db store,", "and publishes each one live as",
           "reading_recorded_v1."])
    d.box("b-ext", 40, 470, 320, 136, "Victron GX device", "[External system]",
          ["A Cerbo or Venus GX: dbus-flashmq", "serves MQTT 3.1.1 on port 1883 with",
           "no auth and no TLS, publishing under", "N/+/+/+/#."])
    d.box("b-mac", 390, 470, 320, 120, "macula-realm", "[Macula infrastructure]",
          ["Endorses the node's identity key and", "admits the boot claim, which must",
           "carry MCL_BOX."])
    d.box("b-mac", 740, 470, 320, 136, "Macula stations, mesh DHT", "[Macula infrastructure]",
          ["The pinned seeds in", "MACULA_STATION_SEEDS carry the fact",
           "over QUIC; the DHT holds the node's", "advertisement."])

    d.edge("M200 150V190H470V220")
    d.text("t-rel", 208, 172, "deploys; sets MCL_BOX")
    d.text("t-rel", 208, 188, "and the broker's address")
    d.edge("M710 300H900V166")
    d.text("t-rel", 718, 292, "publishes reading_recorded_v1")
    d.edge("M200 470V420H470V372")
    d.text("t-rel", 208, 440, "publishes N/+/+/+/# over")
    d.text("t-rel", 208, 456, "MQTT, and answers keepalives")
    d.edge("M550 372V470")
    d.text("t-rel", 558, 404, "boot claim, MCL_BOX")
    d.edge("M630 372V430H900V470")
    d.text("t-rel", 638, 422, "publishes the one fact")
    d.text("t-desc", 40, 640, "The GX speaks first: the service is an MQTT client that subscribes and sends keepalives, and it never writes to the broker.")
    d.text("t-desc", 40, 658, "A reading the mesh does not take is dropped and kept in the store, never replayed, because an old reading would arrive looking current.")
    d.legend(716, boundary=False)
    d.write()


def components():
    d = Diagram("c4-components.svg", "mcl-victron components", 1160, 1400)
    d.bound(16, 40, 1128, 920, "mcl-victron [Container: one OTP release]")

    d.box("b-cmp", 32, 70, 540, 120, "mcl_victron_app", "[OTP application]",
          ["Opens this service's own reckon-db store from mcl_victron_service:event_store/0,",
           "then calls mcl_om:boot/1. Ingest starts only after the store exists, so no",
           "reading is dispatched against a store that is not there."], code=True)
    d.box("b-sys", 32, 222, 540, 136, "mcl_victron_service", "[mcl_om_service behaviour]",
          ["The six callbacks mcl_om resolves by name, plus event_store/0. capabilities/0",
           "is empty: nothing is callable, the readings are the output. health/0 is",
           "degraded while the receiver is not connected, or the broker has been silent",
           "for longer than 1.5 keepalives. identity_spec/0 asks for scope mcl-victron."], code=True)
    d.box("b-cmp", 32, 390, 540, 120, "mcl_victron_sup", "[supervisor, one_for_one]",
          ["Two children, the emitter first so it is registered before the first reading",
           "is recorded: on_victron_reading_recorded_to_mesh, then the receiver's own",
           "supervisor."], code=True)
    d.box("b-cmp", 32, 542, 540, 104, "receive_victron_mqtt_sup", "[supervisor, one_for_one]",
          ["One child, receive_victron_mqtt, restarted permanent.",
           "Kept separate, so the emitter and the receiver restart apart."], code=True)
    d.box("b-cmp", 32, 678, 540, 152, "receive_victron_mqtt", "[gen_server, MQTT 3.1.1 over gen_tcp]",
          ["Subscribes to N/+/+/+/# on the GX's dbus-flashmq broker and dispatches one",
           "record_victron_reading_v1 per notification. mqtt_packet builds and parses the",
           "frames; victron_topic splits a topic into portal, service, instance and path.",
           "Two keepalives: PINGREQ for the session, and R/<portal>/keepalive so the GX",
           "keeps publishing. A broker silent for 1.5 keepalives is left and redialled."], code=True)

    d.box("b-cmp", 588, 70, 540, 168, "on_victron_reading_recorded_to_mesh", "[evoq_event_handler]",
          ["The only place this service's own code publishes to the mesh. Each",
           "recorded reading becomes one reading_recorded_v1 fact, built by",
           "mcl_victron_facts, published from a monitored worker with at most 64",
           "in flight. A reading the mesh does not take is dropped and counted,",
           "never queued, and the count is logged once a minute. A restart's",
           "replay of the store's history is skipped: it is not live."], code=True)
    d.box("b-cmp", 588, 254, 540, 136, "mcl_victron_store", "[reckon-db store, single node]",
          ["Opens the store mcl_victron_service:event_store/0 describes, waits until",
           "reckon_db lists it, and starts the per-store evoq subscription the emitter",
           "receives readings on. Id mcl_victron_store is also named in sys.config.src",
           "and a test compares the two. Single node, no indexes, no integrity key."], code=True)
    d.box("b-cmp", 588, 422, 540, 136, "victron_device_aggregate", "[evoq aggregate]",
          ["victron_device_state applies each event. The aggregate accepts a reading and",
           "appends victron_reading_recorded_v1 to the device's stream in mcl_victron_store.",
           "Snapshots keep an aggregate's start from replaying the whole stream, but",
           "nothing limits the store's size yet (issue #1)."], code=True)
    d.box("b-cmp", 588, 590, 540, 136, "maybe_record_victron_reading", "[command handler, plain Erlang module]",
          ["Handles the command and dispatches it to the device's stream. The stream id",
           "is victron- followed by the first 128 bits of sha256(portal_id), in hex, so",
           "one GX device is one stream whatever its LAN address, and a device that has",
           "never appeared before opens a new one."], code=True)
    d.box("b-cmp", 588, 758, 540, 136, "record_victron_reading_v1", "[evoq command]",
          ["One command per MQTT notification: portal, service, instance, D-Bus path, the",
           "value and observed_at. A zero-byte payload, a non-JSON payload and",
           "{\"value\": null} are absences, not measurements, so no command is built."], code=True)

    d.edge("M200 190V222"); d.text("t-rel", 208, 214, "boots with")
    d.edge("M200 358V390"); d.text("t-rel", 208, 382, "start/1 starts")
    d.edge("M200 510V542"); d.text("t-rel", 208, 534, "starts the receiver's supervisor")
    d.edge("M200 646V678"); d.text("t-rel", 208, 670, "supervises")
    d.edge("M740 254V222"); d.text("t-rel", 748, 246, "the per-store subscription hands it over")
    d.edge("M740 422V390"); d.text("t-rel", 748, 414, "appends victron_reading_recorded_v1")
    d.edge("M740 590V558"); d.text("t-rel", 748, 582, "dispatched to the device's stream")
    d.edge("M740 758V726"); d.text("t-rel", 748, 750, "one command per notification")
    d.edge("M300 830V938H740V894"); d.text("t-rel", 310, 930, "every notification becomes a command")

    d.box("b-mac", 32, 992, 352, 136, "mcl_om", "[library, ~> 1.4]",
          ["boot/1: loads the node identity key,",
           "joins the realm, dials the pinned",
           "stations over QUIC and serves /health",
           "on MCL_HEALTH_PORT. No capabilities."], code=True)
    d.box("b-mac", 404, 992, 352, 136, "macula", "[library, ~> 16.0, wire 1.0]",
          ["QUIC transport, the publish path the",
           "emitter calls, and the signed records",
           "the mesh DHT holds."], code=True)
    d.box("b-cmp", 776, 992, 352, 136, "evoq / reckon_evoq / reckon_db", "[libraries, >= 1.26.1 / >= 2.7.2 / ~> 5.4]",
          ["Event sourcing for the one aggregate,",
           "over this service's own store: commands",
           "in, events out, and the subscription the",
           "emitter reads."], code=True)
    d.box("b-ext", 40, 1160, 1080, 120, "The host environment", "[read by the service; both volumes are in the compose file]",
          ["VICTRON_MQTT_HOST, VICTRON_MQTT_PORT and VICTRON_MQTT_KEEPALIVE_SEC, MCL_DATA_DIR, MCL_HEALTH_PORT, MCL_BOX,",
           "and the realm and station variables. The identity key is /etc/mcl/secrets/identity.key, a named volume; the",
           "store and the recordings are on a second volume at MCL_DATA_DIR, a bulk drive on any fleet node."], code=True)
    d.edge("M1128 316H1140V970H950V992"); d.text("t-rel", 1120, 400, "events in and out", anchor="end")
    d.text("t-desc", 40, 1320, "config/sys.config.src fixes the org, mcl-victron, which the fact's topic carries, and the realm name; the service refuses")
    d.text("t-desc", 40, 1338, "to start unless sha256 of that name is MCL_REALM. It must share a LAN with the GX: dbus-flashmq serves MQTT on the local network only.")
    d.legend(1378)
    d.write()


if __name__ == "__main__":
    for make in (context, components):
        make()

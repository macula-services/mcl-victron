%%% @doc The mcl_om service contract: what mcl-victron is and may do.
%%%
%%% Watches a Victron GX device's dbus-flashmq MQTT broker on the LAN, records
%%% every reading as `victron_reading_recorded_v1' on the device's stream in its
%%% own reckon-db store, and publishes each one live as `reading_recorded_v1'
%%% (mcl_victron_facts). The store is the durable record: ingest never waits for
%%% the mesh.
%%%
%%% The store is this service's own: event_store/0 describes it, and
%%% mcl_victron_app opens it (mcl_victron_store) before mcl_om:boot/1, so it and
%%% its evoq subscription are up when start/1 runs; config/sys.config.src
%%% carries the evoq block that subscription needs. NOT store_id/0 and
%%% data_dir/0: mcl_om 0.35 warns about a service exporting that pair.
-module(mcl_victron_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).
-export([event_store/0]).
-export([hearing/3]).

info() ->
    #{name => <<"mcl-victron">>,
      version => <<"0.1.0">>,
      description => <<"Victron GX (dbus-flashmq MQTT) telemetry, recorded and published on the mesh">>}.

%% The realm name the topic carries must be the realm the pool is in.
start(_Opts) ->
    ok = mcl_victron_facts:check_realm_name(),
    mcl_victron_sup:start_link().

stop(_State) -> ok.

%% Health is whether readings can arrive: connected to the GX's broker, and
%% heard from it within 1.5 keepalives. A receiver that retries a wrong or
%% absent broker forever is alive and useless.
health() ->
    hearing(receive_victron_mqtt:status(), erlang:system_time(millisecond),
            application:get_env(mcl_victron, mqtt_keepalive, 30) * 1000).

%% @doc Health from the receiver's status. Exported for tests.
hearing(disconnected, _Now, _KaMs) ->
    {degraded, not_connected_to_gx};
hearing({connected, LastHeard}, Now, KaMs) when Now - LastHeard > KaMs * 3 div 2 ->
    {degraded, {gx_silent_ms, Now - LastHeard}};
hearing({connected, _LastHeard}, _Now, _KaMs) ->
    ok.

%% Nothing callable: the readings are the output. A query desk would add one.
capabilities() -> [].

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR: publishing its one fact.
identity_spec() ->
    #{scope => <<"mcl-victron">>,
      actions => [<<"publish_reading">>],
      resources => [<<"reading_recorded">>],
      ttl_days => 30}.

%% @doc The reckon-db store, as mcl_victron_app opens it. ⚠ Its id is named in
%% two places, here and in the `evoq' block of config/sys.config.src;
%% mcl_victron_service_tests compares them. Its dir is a volume, on a bulk drive
%% on a fleet node; the default is what a laptop wants. Single node, no
%% secondary indexes, no integrity key.
-spec event_store() -> #{id := atom(), dir := string(), indexes := [term()],
                         mode := single | cluster, integrity := disabled | map()}.
event_store() ->
    #{id => mcl_victron_store,
      dir => chosen(os:getenv("MCL_DATA_DIR")),
      indexes => [],
      mode => single,
      integrity => disabled}.

chosen(false) -> "/tmp/mcl_victron";
chosen("")    -> "/tmp/mcl_victron";
chosen(Path)  -> Path.

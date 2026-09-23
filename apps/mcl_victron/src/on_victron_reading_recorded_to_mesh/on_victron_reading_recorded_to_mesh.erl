%%% @doc Emitter: each `victron_reading_recorded_v1' becomes one
%%% `reading_recorded_v1' fact on the mesh (mcl_victron_facts).
%%%
%%% The only place this service touches the mesh. Ingest (MQTT, command, store)
%%% never waits for it.
%%%
%%% evoq hands a handler the event ENVELOPE; the reading is its `data'.
%%%
%%% ONE PUBLISH PER READING, IN A MONITORED WORKER. Each fact goes out with
%%% macula:publish/4 from a process this one monitors and is not linked to, so
%%% a publish that fails or a pool that dies mid-call is a counted drop rather
%%% than a crash of the emitter. Not mcl_om_pubsub: its publisher is linked to
%%% the caller, blocks the caller on an announcement before it publishes, and
%%% sends two announcement frames per reading. At most ?MAX_IN_FLIGHT publishes
%%% run at once; a reading beyond that is dropped and counted.
%%%
%%% LIVE, NOT QUEUED. A reading the mesh does not take is dropped and kept in
%%% the store, not held back: telemetry replayed after an outage would reach
%%% consumers as if it were current. For the same reason a restart's replay of
%%% the store's history is skipped (replay_policy/0). Drops are reported at most
%%% once a minute: silent loss is a defect, and a warning per reading a flood.
-module(on_victron_reading_recorded_to_mesh).
-behaviour(evoq_event_handler).

-export([interested_in/0, replay_policy/0, init/1, handle_event/4, handle_info/2]).
-export([dropped/1, reported_at/2, in_flight/1, max_in_flight/0]).

-define(MAX_IN_FLIGHT, 64).
-define(REPORT_EVERY_MS, 60_000).

interested_in() -> [<<"victron_reading_recorded_v1">>].

replay_policy() -> skip.

init(_Config) ->
    {ok, #{dropped => 0, reported_at => now_ms(), in_flight => #{}}}.

handle_event(_EventType, Envelope, _Metadata, State) ->
    Fact = mcl_victron_facts:to_wire(mcl_victron_facts:reading_recorded(data(Envelope))),
    {ok, report(publish(mcl_om:mesh_handles(), Fact, State))}.

%% A worker's result arrives as its exit reason.
handle_info({'DOWN', Ref, process, _Pid, Result}, #{in_flight := InFlight} = State) ->
    {noreply, report(finished(maps:is_key(Ref, InFlight), Result,
                              State#{in_flight => maps:remove(Ref, InFlight)}))};
handle_info(_Info, State) ->
    {noreply, State}.

%% @doc Readings the mesh did not take since the last report. For tests.
dropped(#{dropped := N}) -> N.

%% @doc State as if the last report was at `AtMs'. For tests.
reported_at(State, AtMs) -> State#{reported_at => AtMs}.

%% @doc The publishes running, as {Pid, Ref}. For tests.
in_flight(#{in_flight := InFlight}) -> [{Pid, Ref} || {Ref, Pid} <- maps:to_list(InFlight)].

-spec max_in_flight() -> pos_integer().
max_in_flight() -> ?MAX_IN_FLIGHT.

%%====================================================================
%% Publishing
%%====================================================================

data(#{data := Data}) when is_map(Data) -> Data;
data(Event) -> Event.

publish({ok, Pool, Realm}, Fact, #{in_flight := InFlight} = State)
  when map_size(InFlight) < ?MAX_IN_FLIGHT ->
    Topic = mcl_victron_facts:topic(mcl_victron_facts:realm_name(), reading_recorded),
    {Pid, Ref} = spawn_monitor(fun() -> exit({published, macula:publish(Pool, Realm, Topic, Fact)}) end),
    State#{in_flight => InFlight#{Ref => Pid}};
publish(_NoMeshOrFull, _Fact, State) ->
    drop(State).

finished(true, {published, ok}, State) -> State;
finished(true, _Failed, State)         -> drop(State);
finished(false, _Unknown, State)       -> State.

drop(#{dropped := N} = State) -> State#{dropped => N + 1}.

%%====================================================================
%% Reporting
%%====================================================================

report(#{dropped := 0} = State) ->
    State;
report(#{dropped := N, reported_at := At} = State) ->
    due(now_ms() - At >= ?REPORT_EVERY_MS, N, State).

due(false, _N, State) ->
    State;
due(true, N, State) ->
    logger:warning("[mcl-victron] ~b reading(s) not published in the last minute: "
                   "the mesh did not take them; the store has them", [N]),
    State#{dropped => 0, reported_at => now_ms()}.

now_ms() -> erlang:system_time(millisecond).

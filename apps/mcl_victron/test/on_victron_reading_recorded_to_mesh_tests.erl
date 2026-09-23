%% @doc The emitter: each recorded reading, published once, live.
%%
%% evoq hands a handler the event ENVELOPE (event_type, stream_id, version,
%% data => ...), so these tests do too; one that fed the bare data map passed
%% while every real fact went out null. record_victron_reading_tests runs the
%% emitter under the real store subscription as well.
-module(on_victron_reading_recorded_to_mesh_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TOPIC, <<"io.macula/mcl-victron/victron/energy/reading_recorded_v1">>).

emitter_test_() ->
    {foreach,
     fun() ->
             ok = application:set_env(mcl_victron, realm_name, "io.macula"),
             meck:new(mcl_om, [non_strict]),
             meck:new(macula, [non_strict]),
             meck:expect(mcl_om, mesh_handles, fun() -> {ok, pool, <<0:256>>} end),
             meck:expect(macula, publish, fun(_P, _R, _T, _F) -> ok end)
     end,
     fun(_) ->
             meck:unload(macula), meck:unload(mcl_om),
             application:unset_env(mcl_victron, realm_name)
     end,
     [fun a_recorded_reading_is_published_once_on_the_reading_topic/0,
      fun the_published_fact_is_the_reading_not_the_envelope/0,
      fun a_refused_publish_is_counted/0,
      fun a_publish_that_crashes_is_counted_and_does_not_reach_the_emitter/0,
      fun a_dark_mesh_is_counted/0,
      fun readings_beyond_the_in_flight_bound_are_counted/0,
      fun the_count_starts_again_once_reported/0]}.

interested_in_the_recorded_event_test() ->
    ?assertEqual([<<"victron_reading_recorded_v1">>],
                 on_victron_reading_recorded_to_mesh:interested_in()).

%% A restart replays the store's whole history. Republishing it would put
%% hours of stale telemetry on the mesh as if it were live.
replay_is_skipped_test() ->
    ?assertEqual(skip, on_victron_reading_recorded_to_mesh:replay_policy()).

%% No announcement frames, no linked publisher: one publish per reading.
a_recorded_reading_is_published_once_on_the_reading_topic() ->
    S = settled(handle(envelope())),
    ?assertMatch([{published, pool, <<0:256>>, ?TOPIC, _}], drain()),
    ?assertEqual(0, on_victron_reading_recorded_to_mesh:dropped(S)).

the_published_fact_is_the_reading_not_the_envelope() ->
    _ = settled(handle(envelope())),
    [{published, _, _, _, Fact}] = drain(),
    ?assertMatch(#{portal_id := {text, <<"48e7da856abc">>}, service := {text, <<"battery">>},
                   dbus_path := {text, <<"Dc/0/Voltage">>}, value := 52.34,
                   observed_at := 1753303500204}, Fact),
    ?assertNot(maps:is_key(stream_id, Fact)).

a_refused_publish_is_counted() ->
    meck:expect(macula, publish, fun(_, _, _, _) -> {error, frame_refused} end),
    ?assertEqual(1, on_victron_reading_recorded_to_mesh:dropped(settled(handle(envelope())))).

%% A pool that dies mid-call exits the worker. This test process plays the
%% emitter and does not trap exits: a linked worker would take it down here.
a_publish_that_crashes_is_counted_and_does_not_reach_the_emitter() ->
    meck:expect(macula, publish, fun(_, _, _, _) -> exit(noproc) end),
    ?assertEqual(1, on_victron_reading_recorded_to_mesh:dropped(settled(handle(envelope())))).

a_dark_mesh_is_counted() ->
    meck:expect(mcl_om, mesh_handles, fun() -> {error, mesh_unavailable} end),
    {ok, S} = handle(envelope()),
    ?assertEqual(1, on_victron_reading_recorded_to_mesh:dropped(S)).

%% A burst the mesh is slow to take is not an unbounded pile of processes.
readings_beyond_the_in_flight_bound_are_counted() ->
    meck:expect(macula, publish, fun(_, _, _, _) -> receive release -> ok end end),
    {ok, S0} = on_victron_reading_recorded_to_mesh:init(#{}),
    Max = on_victron_reading_recorded_to_mesh:max_in_flight(),
    S = lists:foldl(fun(_, Acc) -> {ok, A} = event(Acc), A end, S0, lists:seq(1, Max + 3)),
    ?assertEqual(3, on_victron_reading_recorded_to_mesh:dropped(S)),
    [exit(P, kill) || {P, _} <- on_victron_reading_recorded_to_mesh:in_flight(S)].

the_count_starts_again_once_reported() ->
    meck:expect(mcl_om, mesh_handles, fun() -> {error, mesh_unavailable} end),
    {ok, S0} = on_victron_reading_recorded_to_mesh:init(#{}),
    {ok, S1} = event(S0),
    {ok, S2} = event(on_victron_reading_recorded_to_mesh:reported_at(S1, 0)),
    ?assertEqual(0, on_victron_reading_recorded_to_mesh:dropped(S2)).

%%------------------------------------------------------------------------------

handle(Envelope) ->
    {ok, State} = on_victron_reading_recorded_to_mesh:init(#{}),
    on_victron_reading_recorded_to_mesh:handle_event(<<"victron_reading_recorded_v1">>,
                                                      Envelope, #{}, State).

event(State) ->
    on_victron_reading_recorded_to_mesh:handle_event(<<"victron_reading_recorded_v1">>,
                                                      envelope(), #{}, State).

%% Feed the workers' monitor messages back, as the handler process would get them.
settled({ok, State}) ->
    receive
        {'DOWN', _, process, _, _} = Down ->
            {noreply, S} = on_victron_reading_recorded_to_mesh:handle_info(Down, State),
            S
    after 2000 -> error(no_worker_result)
    end.

%% Every publish, from whichever worker made it.
drain() ->
    [{published, P, R, T, F} || {_, {macula, publish, [P, R, T, F]}, _} <- meck:history(macula)].

%% The shape evoq_store_subscription hands a handler.
envelope() ->
    #{event_type => <<"victron_reading_recorded_v1">>,
      event_id => <<"e1">>, stream_id => <<"victron-00">>, version => 0,
      tags => [], timestamp => 1, epoch_us => 1,
      data => #{portal_id => <<"48e7da856abc">>, service => <<"battery">>,
                instance => <<"0">>, dbus_path => <<"Dc/0/Voltage">>,
                value => 52.34, observed_at => 1753303500204}}.

%% @doc record_victron_reading against a real reckon-db store through evoq.
%%
%% The store is opened by mcl_om_store:ensure/2, the same call mcl_om:boot/1
%% makes for this service, so the dispatch, the aggregate, the event and its
%% stream are the ones a running node has.
-module(record_victron_reading_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

-define(STORE, mcl_victron_store).

store_test_() ->
    {setup,
     fun start_store/0,
     fun stop_store/1,
     [fun a_reading_is_recorded_on_its_device_s_stream/0,
      {timeout, 30, fun a_recorded_reading_reaches_the_mesh_as_the_reading/0},
      fun a_second_reading_follows_the_first/0,
      fun each_device_has_its_own_stream/0,
      fun a_reading_without_a_path_is_refused/0,
      fun a_reading_with_a_text_value_is_recorded/0]}.

pure_test_() ->
    [fun a_command_needs_every_field/0,
     fun the_stream_is_the_portal/0].

a_reading_is_recorded_on_its_device_s_stream() ->
    {ok, _Version, [Event]} = dispatch(reading(<<"portal-a">>, 52.34)),
    ?assertMatch(#{portal_id := <<"portal-a">>, value := 52.34}, Event),
    [Stored | _] = lists:reverse(stream(<<"portal-a">>)),
    ?assertMatch(#{portal_id := <<"portal-a">>, dbus_path := <<"Dc/0/Voltage">>, value := 52.34},
                 stored_data(Stored)).

%% The whole path: dispatch, the store, the real subscription, the emitter,
%% and the publish it makes. The emitter's unit tests once fed it the bare
%% reading while evoq hands it an envelope, and every real fact went out null.
a_recorded_reading_reaches_the_mesh_as_the_reading() ->
    {ok, _, [_]} = dispatch(reading(<<"portal-f">>, 12.5)),
    {Topic, Fact} = published(<<"portal-f">>, 100),
    ?assertEqual(<<"io.macula/mcl-victron/victron/energy/reading_recorded_v1">>, Topic),
    ?assertMatch(#{value := 12.5, dbus_path := {text, <<"Dc/0/Voltage">>}}, Fact).

published(Portal, 0) -> error({nothing_published_for, Portal});
published(Portal, Tries) ->
    found([{T, F} || {_, {macula, publish, [_, _, T, #{portal_id := {text, P}} = F]}, _}
                         <- meck:history(macula), P =:= Portal], Portal, Tries).

found([Hit | _], _Portal, _Tries) -> Hit;
found([], Portal, Tries) -> timer:sleep(100), published(Portal, Tries - 1).

a_second_reading_follows_the_first() ->
    Before = length(stream(<<"portal-b">>)),
    {ok, _, [_]} = dispatch(reading(<<"portal-b">>, 1.0)),
    {ok, _, [_]} = dispatch(reading(<<"portal-b">>, 2.0)),
    ?assertEqual(Before + 2, length(stream(<<"portal-b">>))).

each_device_has_its_own_stream() ->
    {ok, _, [_]} = dispatch(reading(<<"portal-c">>, 1.0)),
    ?assertEqual([], stream(<<"portal-nobody">>)).

a_reading_without_a_path_is_refused() ->
    {ok, Cmd} = record_victron_reading_v1:new((params(<<"portal-d">>, 1.0))#{dbus_path => <<>>}),
    ?assertMatch({error, _}, maybe_record_victron_reading:dispatch(Cmd)),
    ?assertEqual([], stream(<<"portal-d">>)).

a_reading_with_a_text_value_is_recorded() ->
    {ok, _, [Event]} = dispatch(reading(<<"portal-e">>, <<"Bulk">>)),
    ?assertMatch(#{value := <<"Bulk">>}, Event).

a_command_needs_every_field() ->
    ?assertEqual({error, invalid_params},
                 record_victron_reading_v1:new(maps:remove(dbus_path, params(<<"p">>, 1.0)))).

%% reckon-gater accepts a user stream only as `[a-z]{1,32}-[a-f0-9]{32}'; its
%% predecessor's `victron_device-<portal>' could never be appended to.
the_stream_is_the_portal() ->
    {ok, Cmd} = reading(<<"48e7da856abc">>, 1.0),
    Stream = record_victron_reading_v1:stream_id(Cmd),
    ?assertEqual(ok, reckon_gater_stream_id:validate(Stream)),
    <<Digest:16/binary, _/binary>> = crypto:hash(sha256, <<"48e7da856abc">>),
    ?assertEqual(<<"victron-", (binary:encode_hex(Digest, lowercase))/binary>>, Stream),
    {ok, Other} = reading(<<"48e7da856abd">>, 1.0),
    ?assertNotEqual(Stream, record_victron_reading_v1:stream_id(Other)).

the_device_state_names_its_portal_test() ->
    S = victron_device_state:apply_event(victron_device_state:new(<<"victron-00">>),
                                         #{portal_id => <<"p1">>, observed_at => 5}),
    ?assertEqual(#{portal_id => <<"p1">>, readings_count => 1, last_observed_at => 5},
                 victron_device_state:to_map(S)).

%%------------------------------------------------------------------------------

params(Portal, Value) ->
    #{portal_id => Portal, service => <<"battery">>, instance => <<"0">>,
      dbus_path => <<"Dc/0/Voltage">>, value => Value,
      observed_at => erlang:system_time(millisecond)}.

reading(Portal, Value) ->
    record_victron_reading_v1:new(params(Portal, Value)).

dispatch({ok, Cmd}) ->
    maybe_record_victron_reading:dispatch(Cmd).

stream(Portal) ->
    events(reckon_db_streams:read(?STORE, victron_device_aggregate:stream_id(Portal), 0, 1000, forward)).

stored_data(#event{data = Data}) -> Data.

events({ok, Events}) -> Events;
events({error, {stream_not_found, _}}) -> [];
events({error, _} = Error) -> error(Error).

start_store() ->
    Dir = filename:join(["/tmp", "record_victron_reading_tests",
                         integer_to_list(erlang:unique_integer([positive]))]),
    ok = application:load(evoq),
    [ok = application:set_env(evoq, K, V)
     || {K, V} <- [{event_store_adapter, reckon_evoq_adapter},
                   {subscription_adapter, reckon_evoq_adapter},
                   {snapshot_store_adapter, reckon_evoq_adapter},
                   {store_id, ?STORE}]],
    {ok, Started} = application:ensure_all_started([reckon_db, evoq, reckon_evoq]),
    ok = mcl_om_store:ensure(?STORE, Dir),
    ok = application:set_env(mcl_victron, realm_name, "io.macula"),
    meck:new(mcl_om, [passthrough]),
    meck:new(macula, [passthrough]),
    meck:expect(mcl_om, mesh_handles, fun() -> {ok, pool, crypto:hash(sha256, <<"io.macula">>)} end),
    meck:expect(macula, publish, fun(_Pool, _Realm, _Topic, _Fact) -> ok end),
    {ok, Emitter} = evoq_event_handler:start_link(on_victron_reading_recorded_to_mesh, #{}),
    unlink(Emitter),
    {Dir, Started, Emitter}.

stop_store({Dir, Started, Emitter}) ->
    exit(Emitter, shutdown),
    meck:unload(macula),
    meck:unload(mcl_om),
    application:unset_env(mcl_victron, realm_name),
    [application:stop(App) || App <- lists:reverse(Started)],
    file:del_dir_r(Dir).

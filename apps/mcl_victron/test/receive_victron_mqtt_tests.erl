%% @doc The receiver against a fake dbus-flashmq broker on a local socket.
%%
%% What matters about the receiver is what it SAYS to the GX: one full
%% republish per portal per connection, then keepalives that do not ask for
%% one, and a reconnect when the broker stops answering.
-module(receive_victron_mqtt_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SUPPRESS, <<"{\"keepalive-options\":[\"suppress-republish\"]}">>).

receiver_test_() ->
    {foreach,
     fun start/0,
     fun stop/1,
     [fun(Ctx) -> fun() -> a_notification_becomes_a_reading(Ctx) end end,
      fun(Ctx) -> fun() -> a_new_portal_gets_one_full_republish_then_suppressed_ones(Ctx) end end,
      fun(Ctx) -> fun() -> absences_are_not_readings(Ctx) end end,
      fun(Ctx) -> {timeout, 20, fun() -> a_silent_broker_is_left_and_redialled(Ctx) end} end]}.

keepalive_payloads_test() ->
    ?assertEqual(<<>>, receive_victron_mqtt:keepalive_payload(fresh)),
    ?assertEqual(?SUPPRESS, receive_victron_mqtt:keepalive_payload(republished)).

%%------------------------------------------------------------------------------

a_notification_becomes_a_reading(#{broker := B}) ->
    Sock = handshake(B, [notification(<<"p1">>, <<"{\"value\":52.1}">>)]),
    ?assertMatch([#{portal_id := <<"p1">>, service := <<"battery">>, instance := <<"0">>,
                    dbus_path := <<"Dc/0/Voltage">>, value := 52.1}], readings(1)),
    ?assertMatch({connected, _}, receive_victron_mqtt:status()),
    gen_tcp:close(Sock).

a_new_portal_gets_one_full_republish_then_suppressed_ones(#{broker := B}) ->
    Sock = handshake(B, [notification(<<"p1">>, <<"{\"value\":1}">>)]),
    ?assertEqual({publish, <<"R/p1/keepalive">>, <<>>}, next_publish(Sock, 2000)),
    %% The tick: a PINGREQ, then the portal's keepalive, without a republish.
    ?assertEqual({publish, <<"R/p1/keepalive">>, ?SUPPRESS}, next_publish(Sock, 3000)),
    gen_tcp:send(Sock, <<208, 0>>),  %% PINGRESP
    ?assertEqual({publish, <<"R/p1/keepalive">>, ?SUPPRESS}, next_publish(Sock, 3000)),
    gen_tcp:close(Sock).

absences_are_not_readings(#{broker := B}) ->
    Sock = handshake(B, [notification(<<"p1">>, <<>>),
                         notification(<<"p1">>, <<"{\"value\":null}">>),
                         notification(<<"p1">>, <<"not json">>),
                         notification(<<"p1">>, <<"{\"value\":[1,2]}">>)]),
    ?assertMatch([#{value := [1, 2]}], readings(1)),
    ?assertMatch([_], readings(0)),
    gen_tcp:close(Sock).

%% No PINGRESP for 1.5 keepalives: the receiver drops the socket and dials
%% again, as it would for a GX that lost power without closing anything.
a_silent_broker_is_left_and_redialled(#{broker := B}) ->
    Sock = handshake(B, []),
    {ok, Again} = gen_tcp:accept(B, 10000),
    ?assertEqual({error, closed}, drain_until_closed(Sock)),
    gen_tcp:close(Again).

%%------------------------------------------------------------------------------

start() ->
    {ok, B} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(B),
    [ok = application:set_env(mcl_victron, K, V)
     || {K, V} <- [{mqtt_host, "127.0.0.1"}, {mqtt_port, Port}, {mqtt_keepalive, 1}]],
    meck:new(maybe_record_victron_reading, [passthrough]),
    meck:expect(maybe_record_victron_reading, dispatch, fun(_Cmd) -> {ok, 1, []} end),
    {ok, Pid} = receive_victron_mqtt:start_link(),
    unlink(Pid),
    #{broker => B, receiver => Pid}.

stop(#{broker := B, receiver := Pid}) ->
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ok end,
    gen_tcp:close(B),
    meck:unload(maybe_record_victron_reading),
    [application:unset_env(mcl_victron, K) || K <- [mqtt_host, mqtt_port, mqtt_keepalive]].

%% CONNECT in, CONNACK out; SUBSCRIBE in, SUBACK out with `Coalesced' in the
%% same segment, as a real broker sends a retained notification.
handshake(B, Coalesced) ->
    {ok, Sock} = gen_tcp:accept(B, 10000),
    {ok, {other, 1}} = next(Sock, 5000),
    ok = gen_tcp:send(Sock, <<32, 2, 0, 0>>),
    {ok, {other, 8}} = next(Sock, 5000),
    ok = gen_tcp:send(Sock, iolist_to_binary([<<144, 3, 0, 1, 0>> | Coalesced])),
    Sock.

notification(Portal, Payload) ->
    mqtt_packet:publish(<<"N/", Portal/binary, "/battery/0/Dc/0/Voltage">>, Payload).

next(Sock, Timeout) -> next(Sock, <<>>, Timeout).

next(Sock, Buf, Timeout) ->
    got(mqtt_packet:decode(Buf), Sock, Buf, Timeout).

got({ok, Packet, _Rest}, _Sock, _Buf, _Timeout) -> {ok, Packet};
got(more, Sock, Buf, Timeout) ->
    {ok, Data} = gen_tcp:recv(Sock, 0, Timeout),
    next(Sock, <<Buf/binary, Data/binary>>, Timeout).

%% The next PUBLISH the receiver sends, skipping PINGREQs. One packet per recv
%% is enough here: the receiver writes each packet separately.
next_publish(Sock, Timeout) ->
    {ok, Data} = gen_tcp:recv(Sock, 0, Timeout),
    first_publish(Data, Sock, Timeout).

first_publish(<<>>, Sock, Timeout) ->
    next_publish(Sock, Timeout);
first_publish(Data, Sock, Timeout) ->
    case mqtt_packet:decode(Data) of
        {ok, {publish, _, _} = P, _Rest} -> P;
        {ok, _Other, Rest} -> first_publish(Rest, Sock, Timeout)
    end.

%% The readings dispatched so far, once there are `N' of them (0: after a pause
%% long enough for any stray one to arrive).
readings(0) ->
    timer:sleep(300),
    dispatched();
readings(N) ->
    readings(N, 30).

readings(N, 0) -> error({missing_readings, N, dispatched()});
readings(N, Tries) ->
    settled(length(dispatched()) >= N, N, Tries).

settled(true, _N, _Tries) -> dispatched();
settled(false, N, Tries) -> timer:sleep(100), readings(N, Tries - 1).

dispatched() ->
    [record_victron_reading_v1:to_map(Cmd)
     || {_, {maybe_record_victron_reading, dispatch, [Cmd]}, _} <- meck:history(maybe_record_victron_reading)].

drain_until_closed(Sock) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, _} -> drain_until_closed(Sock);
        Error -> Error
    end.

%%% @doc Watches a Victron Venus OS dbus-flashmq broker on the LAN and
%%% dispatches one `record_victron_reading_v1' command per notification.
%%%
%%% Speaks MQTT 3.1.1 over `gen_tcp' via `mqtt_packet' (see that module for why
%%% there is no MQTT library). Reads the `mcl_victron' app env: mqtt_host,
%%% mqtt_port, mqtt_keepalive (seconds). Subscribes to `N/+/+/+/#', so one
%%% service serves every GX on the LAN.
%%%
%%% TWO KEEPALIVES, NOT THE SAME THING. `PINGREQ' keeps the broker's session.
%%% `R/<portal>/keepalive' keeps the GX publishing values (its timeout is 60 s).
%%% An EMPTY keepalive also makes the GX republish every topic it has; that is
%%% how a new connection learns the current values, so each portal gets one per
%%% connection. After that it is `suppress-republish': the GX then sends only
%%% what changes. Its predecessor sent the empty one every 30 s, re-recording
%%% every value of the device twice a minute, faster than the store can write.
%%%
%%% A GX that vanishes without closing the socket (power, a switch) would leave
%%% it open and silent for the kernel's retry time. So every tick checks that
%%% the broker answered within 1.5 keepalives, and reconnects if not.
%%%
%%% Whether it is connected and when it last heard the broker are kept where
%%% /health reads them without a call (status/0).
-module(receive_victron_mqtt).
-behaviour(gen_server).

-export([start_link/0, status/0, keepalive_payload/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SUBSCRIBE_TOPIC, <<"N/+/+/+/#">>).
-define(RECONNECT_MS, 5_000).
-define(DEFAULT_KA_SEC, 30).
-define(CONNECT_TIMEOUT_MS, 10_000).
-define(SUBSCRIBE_PACKET_ID, 1).
-define(STATUS, {?MODULE, status}).

-record(state, {
    socket         :: gen_tcp:socket() | undefined,
    buffer = <<>>  :: binary(),
    %% Portals seen on this connection; each has had its one full republish.
    portals = sets:new([{version, 2}]) :: sets:set(binary()),
    ka_interval_ms :: pos_integer(),
    ka_timer       :: reference() | undefined,
    last_rx_at = 0 :: integer(),
    client_id      :: binary()
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc `{connected, LastHeardMs}' or `disconnected'.
-spec status() -> {connected, integer()} | disconnected.
status() ->
    persistent_term:get(?STATUS, disconnected).

%% @doc The keepalive a portal gets: the first on a connection asks for every
%% topic, the rest keep the session without a republish.
-spec keepalive_payload(fresh | republished) -> binary().
keepalive_payload(fresh)       -> <<>>;
keepalive_payload(republished) -> <<"{\"keepalive-options\":[\"suppress-republish\"]}">>.

init([]) ->
    process_flag(trap_exit, true),
    KaSec = application:get_env(mcl_victron, mqtt_keepalive, ?DEFAULT_KA_SEC),
    self() ! connect,
    publish_status(disconnected),
    {ok, #state{ka_interval_ms = KaSec * 1000, client_id = client_id()}}.

handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(connect, S) ->
    {noreply, connected(connect_and_subscribe(S), S)};
handle_info({tcp, Sock, Data}, #state{socket = Sock, buffer = Buf} = S) ->
    ok = inet:setopts(Sock, [{active, once}]),
    {noreply, drain(<<Buf/binary, Data/binary>>, heard(S))};
handle_info({tcp_closed, Sock}, #state{socket = Sock} = S) ->
    logger:warning("[receive_victron_mqtt] broker closed the connection; "
                   "reconnecting in ~pms", [?RECONNECT_MS]),
    {noreply, reconnect_later(S)};
handle_info({tcp_error, Sock, Reason}, #state{socket = Sock} = S) ->
    logger:warning("[receive_victron_mqtt] socket error ~p; reconnecting in ~pms",
                   [Reason, ?RECONNECT_MS]),
    {noreply, reconnect_later(S)};
handle_info(send_keepalive, #state{socket = Sock} = S) when Sock =/= undefined ->
    {noreply, keepalive(answering(now_ms() - S#state.last_rx_at, S), S)};
handle_info(_Other, S) ->
    {noreply, S}.

terminate(_Reason, #state{socket = Sock, ka_timer = Timer}) ->
    cancel_timer(Timer),
    say_goodbye(Sock),
    publish_status(disconnected),
    ok.

%%% Keepalive

%% Silence past 1.5 keepalives means the GX is gone even if the socket says not.
answering(SinceMs, #state{ka_interval_ms = Ka}) -> SinceMs =< Ka * 3 div 2.

keepalive(false, S) ->
    logger:warning("[receive_victron_mqtt] no answer from the broker in 1.5 keepalives; "
                   "reconnecting"),
    reconnect_later(S);
keepalive(true, #state{socket = Sock, portals = Portals} = S) ->
    _ = gen_tcp:send(Sock, mqtt_packet:pingreq()),
    sets:fold(fun(Portal, ok) -> nudge(Sock, Portal, republished) end, ok, Portals),
    S#state{ka_timer = schedule_keepalive(S#state.ka_interval_ms)}.

nudge(Sock, Portal, Stage) ->
    _ = gen_tcp:send(Sock, mqtt_packet:publish(<<"R/", Portal/binary, "/keepalive">>,
                                               keepalive_payload(Stage))),
    ok.

%%% Connection

connected({ok, Sock, Rest}, S) ->
    logger:info("[receive_victron_mqtt] connected and subscribed to ~s", [?SUBSCRIBE_TOPIC]),
    S1 = heard(S#state{socket = Sock, buffer = <<>>, portals = sets:new([{version, 2}]),
                       ka_timer = schedule_keepalive(S#state.ka_interval_ms)}),
    %% Drain whatever rode in with SUBACK before going idle.
    drain(Rest, S1);
connected({error, Reason}, S) ->
    logger:warning("[receive_victron_mqtt] connect failed: ~p; retrying in ~pms",
                   [Reason, ?RECONNECT_MS]),
    erlang:send_after(?RECONNECT_MS, self(), connect),
    S#state{socket = undefined}.

reconnect_later(#state{socket = Sock, ka_timer = Timer} = S) ->
    cancel_timer(Timer),
    close(Sock),
    publish_status(disconnected),
    erlang:send_after(?RECONNECT_MS, self(), connect),
    S#state{socket = undefined, buffer = <<>>, ka_timer = undefined,
            portals = sets:new([{version, 2}])}.

heard(S) ->
    Now = now_ms(),
    publish_status({connected, Now}),
    S#state{last_rx_at = Now}.

publish_status(Status) ->
    persistent_term:put(?STATUS, Status).

close(undefined) -> ok;
close(Sock)      -> catch gen_tcp:close(Sock), ok.

say_goodbye(undefined) -> ok;
say_goodbye(Sock) ->
    _ = gen_tcp:send(Sock, mqtt_packet:disconnect()),
    close(Sock).

connect_and_subscribe(#state{ka_interval_ms = Ka, client_id = ClientId}) ->
    Host = application:get_env(mcl_victron, mqtt_host, "127.0.0.1"),
    Port = application:get_env(mcl_victron, mqtt_port, 1883),
    Opts = [binary, {active, false}, {packet, raw}, {keepalive, true}],
    opened(gen_tcp:connect(Host, Port, Opts, ?CONNECT_TIMEOUT_MS), ClientId, Ka div 1000).

opened({error, Reason}, _ClientId, _KeepaliveSec) ->
    {error, Reason};
opened({ok, Sock}, ClientId, KeepaliveSec) ->
    ok = gen_tcp:send(Sock, mqtt_packet:connect(ClientId, KeepaliveSec)),
    acked(await(Sock, <<>>), Sock).

%% CONNACK return code 0 is "accepted"; anything else is a refusal, not to be
%% papered over: ignored, it leaves a socket open and permanently silent.
acked({ok, {connack, 0}, Rest}, Sock) ->
    ok = gen_tcp:send(Sock, mqtt_packet:subscribe(?SUBSCRIBE_PACKET_ID, ?SUBSCRIBE_TOPIC)),
    subscribed(await(Sock, Rest), Sock);
acked({ok, {connack, Code}, _Rest}, Sock) ->
    close(Sock),
    {error, {connection_refused, Code}};
acked({ok, Other, _Rest}, Sock) ->
    close(Sock),
    {error, {unexpected, Other}};
acked({error, Reason}, Sock) ->
    close(Sock),
    {error, Reason}.

%% `Rest' MUST be carried forward: the retained N/<portal>/system/0/Serial can
%% arrive in the same segment as SUBACK, and a notification is how a portal is
%% learned at all.
subscribed({ok, {suback, _Id}, Rest}, Sock) ->
    ok = inet:setopts(Sock, [{active, once}]),
    {ok, Sock, Rest};
subscribed({ok, Other, _Rest}, Sock) ->
    close(Sock),
    {error, {unexpected, Other}};
subscribed({error, Reason}, Sock) ->
    close(Sock),
    {error, Reason}.

%% Blocking read of exactly one packet, during the handshake only.
await(Sock, Buf) ->
    awaited(mqtt_packet:decode(Buf), Sock, Buf).

awaited({ok, Packet, Rest}, _Sock, _Buf) -> {ok, Packet, Rest};
awaited({error, Reason}, _Sock, _Buf) -> {error, Reason};
awaited(more, Sock, Buf) -> read_more(gen_tcp:recv(Sock, 0, ?CONNECT_TIMEOUT_MS), Sock, Buf).

read_more({ok, Data}, Sock, Buf) -> await(Sock, <<Buf/binary, Data/binary>>);
read_more({error, Reason}, _Sock, _Buf) -> {error, Reason}.

%%% Notifications

%% Every complete packet the buffer holds, keeping the remainder.
drain(Buf, S) ->
    drained(mqtt_packet:decode(Buf), Buf, S).

drained({ok, Packet, Rest}, _Buf, S) ->
    drain(Rest, handle_packet(Packet, S));
drained(more, Buf, S) ->
    S#state{buffer = Buf};
drained({error, Reason}, _Buf, S) ->
    logger:warning("[receive_victron_mqtt] malformed packet (~p); resetting the stream", [Reason]),
    %% A malformed remaining-length cannot be resynchronised from.
    reconnect_later(S).

handle_packet({publish, <<"N/", _/binary>> = Topic, Payload}, S) ->
    parsed(victron_topic:parse_notification(Topic), Payload, S);
handle_packet(_Other, S) ->
    S.

parsed({ok, #{portal := Portal} = Parsed}, Payload, S) ->
    S1 = learn_portal(sets:is_element(Portal, S#state.portals), Portal, S),
    ok = recorded(decode_value(Payload), Parsed),
    S1;
parsed(error, _Payload, S) ->
    S.

%% A portal seen for the first time on this connection gets its full republish
%% now, not at the next tick: that is what brings its current values.
learn_portal(true, _Portal, S) ->
    S;
learn_portal(false, Portal, #state{socket = Sock, portals = Portals} = S) ->
    nudge(Sock, Portal, fresh),
    S#state{portals = sets:add_element(Portal, Portals)}.

%% A zero-byte payload (the device went away), non-JSON, or {"value": null}
%% are absences, not measurements, and are not recorded.
decode_value(<<>>) ->
    error;
decode_value(Bin) ->
    try json:decode(Bin) of
        #{<<"value">> := null} -> error;
        #{<<"value">> := V}    -> {ok, V};
        _                      -> error
    catch _:_ -> error
    end.

recorded({ok, Value}, #{portal := P, service := S, instance := I, dbus_path := D}) ->
    commanded(record_victron_reading_v1:new(#{portal_id => P, service => S, instance => I,
                                             dbus_path => D, value => Value,
                                             observed_at => now_ms()}), [P, S, I, D]);
recorded(error, _Parsed) ->
    ok.

commanded({ok, Cmd}, Where) ->
    dispatched(maybe_record_victron_reading:dispatch(Cmd), Where);
commanded({error, Reason}, Where) ->
    logger:warning("[receive_victron_mqtt] bad reading ~p: ~p", [Where, Reason]).

dispatched({ok, _Version, _Events}, _Where) ->
    ok;
dispatched({error, Reason}, Where) ->
    logger:warning("[receive_victron_mqtt] reading ~p not recorded: ~p", [Where, Reason]).

%% One per instance: two instances against one GX with the same client id
%% would take each other's session every reconnect.
client_id() ->
    <<"mcl-victron-", (binary:encode_hex(crypto:strong_rand_bytes(6), lowercase))/binary>>.

schedule_keepalive(Interval) when is_integer(Interval), Interval > 0 ->
    erlang:send_after(Interval, self(), send_keepalive).

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> _ = erlang:cancel_timer(Ref), ok.

now_ms() -> erlang:system_time(millisecond).

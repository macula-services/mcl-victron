%%% @doc MQTT 3.1.1 wire codec, limited to what a Victron GX needs.
%%%
%%% WHY THIS EXISTS instead of a library. The only broker this service ever
%%% talks to is `dbus-flashmq' on a Victron GX, on the LAN, on port 1883,
%%% with no auth and no TLS. The exchange is: connect, subscribe to one
%%% filter, receive PUBLISHes, send a keepalive every 30 s. That is five
%%% packet types.
%%%
%%% `emqtt' was the original dependency and could not be made to work:
%%% the pinned 1.13.5 does not exist on hex, so this service had never built
%%% from a clean checkout; 1.14.7 pins `cowlib' to exactly 2.13.0 while its
%%% own `gun ~> 2.1' resolves to 2.4.1, which requires cowlib >= 2.18, so
%%% that release is internally unsatisfiable; and 1.15 still could not be
%%% resolved alongside cowboy under rebar3's first-wins resolver. It also
%%% drags in `quicer', an msquic NIF, which the platform deliberately
%%% excludes: macula uses Quinn, pure Rust, and no msquic in the data path.
%%%
%%% Trading a broken 4-dependency subtree for ~200 lines of a stable,
%%% frozen, 2014 protocol is the cheaper and more honest side of that deal.
%%%
%%% Scope, deliberately: QoS 0 only, no will, no auth, no retain handling,
%%% no packet-identifier reuse beyond SUBSCRIBE. The GX publishes at QoS 0
%%% and this service never publishes anything but keepalives.
-module(mqtt_packet).

-export([connect/2, subscribe/2, publish/2, pingreq/0, disconnect/0]).
-export([decode/1]).

-export_type([packet/0]).

%% Control packet types (MQTT 3.1.1 §2.2.1).
-define(CONNECT,     1).
-define(CONNACK,     2).
-define(PUBLISH,     3).
-define(SUBSCRIBE,   8).
-define(SUBACK,      9).
-define(PINGREQ,    12).
-define(PINGRESP,   13).
-define(DISCONNECT, 14).

-type packet() :: {connack, non_neg_integer()}
                | {suback, non_neg_integer()}
                | {publish, binary(), binary()}
                | pingresp
                | {other, non_neg_integer()}.

%%------------------------------------------------------------------
%% Encode
%%------------------------------------------------------------------

%% @doc CONNECT with a clean session and no credentials.
%%
%% `KeepaliveSec' is the BROKER-side timer: if it hears nothing for 1.5x
%% this, it drops us. It is not the same clock as the Victron
%% `R/<portal>/keepalive' application message, which asks the GX to keep
%% publishing values. Both exist and they are unrelated.
-spec connect(binary(), non_neg_integer()) -> binary().
connect(ClientId, KeepaliveSec) when is_binary(ClientId) ->
    %% Protocol name, level 4 (3.1.1), flags = clean session only, keepalive.
    Variable = <<(str(<<"MQTT">>))/binary, 4:8, 2:8, KeepaliveSec:16/big>>,
    packet(?CONNECT, 0, <<Variable/binary, (str(ClientId))/binary>>).

%% @doc SUBSCRIBE to one filter at QoS 0. Fixed-header flags are 2 for
%% SUBSCRIBE, which the spec mandates rather than leaves free.
-spec subscribe(non_neg_integer(), binary()) -> binary().
subscribe(PacketId, TopicFilter) when is_binary(TopicFilter) ->
    packet(?SUBSCRIBE, 2,
           <<PacketId:16/big, (str(TopicFilter))/binary, 0:8>>).

%% @doc PUBLISH at QoS 0: no packet identifier, no acknowledgement.
-spec publish(binary(), binary()) -> binary().
publish(Topic, Payload) when is_binary(Topic), is_binary(Payload) ->
    packet(?PUBLISH, 0, <<(str(Topic))/binary, Payload/binary>>).

-spec pingreq() -> binary().
pingreq() -> packet(?PINGREQ, 0, <<>>).

-spec disconnect() -> binary().
disconnect() -> packet(?DISCONNECT, 0, <<>>).

%%------------------------------------------------------------------
%% Decode
%%------------------------------------------------------------------

%% @doc Take one packet off the head of a buffer.
%%
%% `more' means the buffer holds an incomplete packet and the caller should
%% keep accumulating. TCP gives no message boundaries, so this is the normal
%% case, not an error.
-spec decode(binary()) -> {ok, packet(), binary()} | more | {error, term()}.
decode(<<Type:4, _Flags:4, Rest/binary>> = Buf) ->
    remaining(varint(Rest), Type, Buf);
decode(_Short) ->
    more.

remaining(more, _Type, _Buf) ->
    more;
remaining({ok, Len, Body}, Type, _Buf) when byte_size(Body) >= Len ->
    <<Payload:Len/binary, Rest/binary>> = Body,
    {ok, body(Type, Payload), Rest};
remaining({ok, _Len, _Body}, _Type, _Buf) ->
    more;
remaining({error, R}, _Type, _Buf) ->
    {error, R}.

body(?CONNACK, <<_Session:8, Code:8, _/binary>>) -> {connack, Code};
body(?SUBACK, <<PacketId:16/big, _/binary>>)     -> {suback, PacketId};
body(?PINGRESP, _Payload)                        -> pingresp;
%% QoS 0 PUBLISH: topic then payload, with no packet identifier between.
%% The service only ever subscribes at QoS 0, so a packet identifier here
%% would mean the broker ignored our granted QoS.
body(?PUBLISH, <<Len:16/big, Topic:Len/binary, Payload/binary>>) ->
    {publish, Topic, Payload};
body(Type, _Payload) ->
    {other, Type}.

%%------------------------------------------------------------------
%% Internals
%%------------------------------------------------------------------

packet(Type, Flags, Body) ->
    <<Type:4, Flags:4, (varint_encode(byte_size(Body)))/binary, Body/binary>>.

%% Length-prefixed UTF-8 string (§1.5.3).
str(Bin) -> <<(byte_size(Bin)):16/big, Bin/binary>>.

%% Remaining Length: 7 bits per byte, high bit = continuation, max 4 bytes
%% (§2.2.3).
varint_encode(N) when N < 128 ->
    <<N:8>>;
varint_encode(N) ->
    <<1:1, (N rem 128):7, (varint_encode(N div 128))/binary>>.

varint(Bin) -> varint(Bin, 0, 1, 0).

varint(_Bin, _Acc, _Mult, 4) ->
    {error, malformed_remaining_length};
varint(<<0:1, Value:7, Rest/binary>>, Acc, Mult, _N) ->
    {ok, Acc + Value * Mult, Rest};
varint(<<1:1, Value:7, Rest/binary>>, Acc, Mult, N) ->
    varint(Rest, Acc + Value * Mult, Mult * 128, N + 1);
varint(_Incomplete, _Acc, _Mult, _N) ->
    more.

%%% EUnit tests for the MQTT 3.1.1 codec.
%%%
%%% This is a hand-written implementation of someone else's protocol, which
%%% is exactly the shape that produces a wrong-and-internally-consistent
%%% result: our encoder and our decoder can agree with each other while both
%%% disagree with the broker. So the tests check bytes against the spec
%%% (fixed headers, the variable-byte Remaining Length boundaries from
%%% §2.2.3) rather than only round-tripping our own output.
-module(mqtt_packet_tests).

-include_lib("eunit/include/eunit.hrl").

%%------------------------------------------------------------------
%% Encode: fixed headers and byte layout
%%------------------------------------------------------------------

connect_has_protocol_name_and_level_test() ->
    <<Type:4, Flags:4, Rest/binary>> = mqtt_packet:connect(<<"cid">>, 30),
    ?assertEqual(1, Type),
    ?assertEqual(0, Flags),
    %% Remaining Length, then: "MQTT", level 4, connect flags, keepalive.
    <<_Len:8, 4:16, "MQTT", Level:8, ConnFlags:8, Keepalive:16/big,
      3:16, "cid">> = Rest,
    ?assertEqual(4, Level),
    ?assertEqual(2, ConnFlags),          %% clean session, nothing else
    ?assertEqual(30, Keepalive).

%% The spec MANDATES flags 0010 on SUBSCRIBE; a broker must reject anything
%% else, and getting it wrong yields a silent non-subscription.
subscribe_uses_mandatory_flags_test() ->
    <<Type:4, Flags:4, _Len:8, PacketId:16/big, 9:16, "N/+/+/+/#", QoS:8>> =
        mqtt_packet:subscribe(7, <<"N/+/+/+/#">>),
    ?assertEqual(8, Type),
    ?assertEqual(2, Flags),
    ?assertEqual(7, PacketId),
    ?assertEqual(0, QoS).

publish_qos0_carries_no_packet_identifier_test() ->
    <<Type:4, Flags:4, _Len:8, 5:16, "R/abc", Payload/binary>> =
        mqtt_packet:publish(<<"R/abc">>, <<>>),
    ?assertEqual(3, Type),
    ?assertEqual(0, Flags),
    ?assertEqual(<<>>, Payload).

pingreq_and_disconnect_are_two_bytes_test() ->
    ?assertEqual(<<12:4, 0:4, 0:8>>, mqtt_packet:pingreq()),
    ?assertEqual(<<14:4, 0:4, 0:8>>, mqtt_packet:disconnect()).

%%------------------------------------------------------------------
%% Remaining Length: the variable-byte boundaries
%%------------------------------------------------------------------

%% 127/128 and 16383/16384 are where the continuation bit turns on. An
%% off-by-one here corrupts every packet longer than the boundary, and a
%% Victron full-publish burst is full of them.
remaining_length_boundaries_test() ->
    [?assertEqual(N, encoded_body_len(N))
     || N <- [0, 1, 127, 128, 129, 16383, 16384, 200000]].

encoded_body_len(N) ->
    Payload = binary:copy(<<"x">>, N),
    Bytes   = mqtt_packet:publish(<<>>, Payload),
    %% Strip fixed header byte, decode the varint, check it matches, and
    %% confirm the body really is that long.
    <<_FixedHeader:8, Rest/binary>> = Bytes,
    {Len, Body} = read_varint(Rest, 0, 1),
    ?assertEqual(byte_size(Body), Len),
    Len - 2.                             %% minus the 2-byte empty topic

read_varint(<<0:1, V:7, Rest/binary>>, Acc, Mult) -> {Acc + V * Mult, Rest};
read_varint(<<1:1, V:7, Rest/binary>>, Acc, Mult) ->
    read_varint(Rest, Acc + V * Mult, Mult * 128).

%%------------------------------------------------------------------
%% Decode
%%------------------------------------------------------------------

decode_connack_test() ->
    ?assertEqual({ok, {connack, 0}, <<>>}, mqtt_packet:decode(<<2:4, 0:4, 2, 0, 0>>)),
    ?assertEqual({ok, {connack, 5}, <<>>}, mqtt_packet:decode(<<2:4, 0:4, 2, 0, 5>>)).

decode_suback_test() ->
    ?assertEqual({ok, {suback, 1}, <<>>},
                 mqtt_packet:decode(<<9:4, 0:4, 3, 0, 1, 0>>)).

decode_pingresp_test() ->
    ?assertEqual({ok, pingresp, <<>>}, mqtt_packet:decode(<<13:4, 0:4, 0>>)).

decode_publish_test() ->
    Topic = <<"N/portal/battery/0/Dc/0/Voltage">>,
    Body  = <<"{\"value\": 52.34}">>,
    Bytes = mqtt_packet:publish(Topic, Body),
    ?assertEqual({ok, {publish, Topic, Body}, <<>>}, mqtt_packet:decode(Bytes)).

%% TCP has no message boundaries, so a short buffer is the NORMAL case and
%% must not be reported as an error.
decode_partial_buffer_is_more_not_error_test() ->
    Bytes = mqtt_packet:publish(<<"N/a/b/0/P">>, <<"{\"value\": 1}">>),
    [?assertEqual(more, mqtt_packet:decode(binary:part(Bytes, 0, N)))
     || N <- lists:seq(0, byte_size(Bytes) - 1)],
    ?assertMatch({ok, {publish, _, _}, <<>>}, mqtt_packet:decode(Bytes)).

%% A full-publish burst arrives coalesced; the drain loop depends on the
%% remainder being returned intact.
decode_returns_remainder_for_coalesced_packets_test() ->
    A = mqtt_packet:publish(<<"N/a/b/0/X">>, <<"1">>),
    B = mqtt_packet:publish(<<"N/a/b/0/Y">>, <<"2">>),
    {ok, {publish, <<"N/a/b/0/X">>, <<"1">>}, Rest} =
        mqtt_packet:decode(<<A/binary, B/binary>>),
    ?assertEqual({ok, {publish, <<"N/a/b/0/Y">>, <<"2">>}, <<>>},
                 mqtt_packet:decode(Rest)).

%% Five continuation bytes is malformed per §2.2.3; the stream cannot be
%% resynchronised and the caller must reconnect rather than re-parse forever.
decode_rejects_malformed_remaining_length_test() ->
    ?assertEqual({error, malformed_remaining_length},
                 mqtt_packet:decode(<<3:4, 0:4, 255, 255, 255, 255, 255>>)).

%% A zero-byte payload is dbus-flashmq's device-disappeared signal, so it
%% must decode cleanly rather than look like a truncated packet.
decode_empty_payload_test() ->
    ?assertEqual({ok, {publish, <<"N/a/b/0/Z">>, <<>>}, <<>>},
                 mqtt_packet:decode(mqtt_packet:publish(<<"N/a/b/0/Z">>, <<>>))).

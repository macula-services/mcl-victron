%% @doc The one fact mcl-victron publishes, and the realm it publishes in.
-module(mcl_victron_facts_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REALM_NAME, <<"io.macula">>).

%% One topic for every reading: the device and the D-Bus path are in the
%% payload, never in the topic name.
reading_topic_test() ->
    ?assertEqual(<<"io.macula/mcl-victron/victron/energy/reading_recorded_v1">>,
                 mcl_victron_facts:topic(?REALM_NAME, reading_recorded)).

reading_fact_names_the_device_and_the_path_test() ->
    ?assertEqual(#{portal_id => <<"48e7da856abc">>, service => <<"battery">>,
                   instance => <<"0">>, dbus_path => <<"Dc/0/Voltage">>,
                   value => 52.34, observed_at => 1753303500204},
                 mcl_victron_facts:reading_recorded(event(52.34))).

%%------------------------------------------------------------------------------
%% On the wire: floats as floats, text as text, no booleans
%%------------------------------------------------------------------------------

a_float_leaves_as_a_float_test() ->
    ?assertEqual(52.34, maps:get(value, wire(52.34))),
    ?assertEqual(-1234.5, maps:get(value, wire(-1234.5))).

an_integer_leaves_as_an_integer_test() ->
    ?assertEqual(87, maps:get(value, wire(87))).

text_leaves_as_text_test() ->
    Fact = wire(<<"Bulk">>),
    ?assertEqual({text, <<"Bulk">>}, maps:get(value, Fact)),
    ?assertEqual({text, <<"battery">>}, maps:get(service, Fact)),
    ?assertEqual({text, <<"Dc/0/Voltage">>}, maps:get(dbus_path, Fact)).

a_boolean_leaves_as_one_or_zero_test() ->
    ?assertEqual(1, maps:get(value, wire(true))),
    ?assertEqual(0, maps:get(value, wire(false))).

%% dbus-flashmq sends arrays and objects for some paths.
structured_values_are_tagged_throughout_test() ->
    ?assertEqual([{text, <<"a">>}, 2], maps:get(value, wire([<<"a">>, 2]))),
    ?assertEqual(#{<<"k">> => {text, <<"v">>}}, maps:get(value, wire(#{<<"k">> => <<"v">>}))).

%% The check that cannot drift: macula's own admissibility rule.
every_value_shape_is_admissible_on_the_mesh_test() ->
    [?assertEqual(ok, macula_frame:check_payload(wire(V)))
     || V <- [52.34, -1234.5, 0.0, 87, <<"Bulk">>, true, false,
              [<<"a">>, 1], #{<<"k">> => <<"v">>}]].

%%------------------------------------------------------------------------------
%% The realm name the topic carries must be the realm the pool is in
%%------------------------------------------------------------------------------

a_realm_name_matching_the_tag_is_accepted_test() ->
    ?assertEqual(ok, mcl_victron_facts:check_realm_name(?REALM_NAME,
                                                        crypto:hash(sha256, ?REALM_NAME))).

a_realm_name_not_matching_the_tag_refuses_to_start_test() ->
    ?assertError({mcl_victron_realm_name_mismatch, ?REALM_NAME, _},
                 mcl_victron_facts:check_realm_name(?REALM_NAME, <<0:256>>)).

an_unset_realm_name_refuses_to_start_test() ->
    application:unset_env(mcl_victron, realm_name),
    ?assertError({mcl_victron_realm_name_unset, realm_name}, mcl_victron_facts:realm_name()).

event(Value) ->
    #{portal_id => <<"48e7da856abc">>, service => <<"battery">>, instance => <<"0">>,
      dbus_path => <<"Dc/0/Voltage">>, value => Value, observed_at => 1753303500204}.

wire(Value) ->
    mcl_victron_facts:to_wire(mcl_victron_facts:reading_recorded(event(Value))).

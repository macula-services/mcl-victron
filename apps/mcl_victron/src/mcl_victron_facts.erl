%%% @doc mcl-victron's public contract on the mesh: one fact.
%%%
%%%   reading_recorded_v1 on `<realm>/mcl-victron/victron/energy/reading_recorded_v1'
%%%     portal_id    the GX device's VRM portal id
%%%     service      battery, solarcharger, vebus, grid, system, ...
%%%     instance     the device instance, as text ("0")
%%%     dbus_path    the D-Bus path under the service, e.g. "Dc/0/Voltage"
%%%     value        what the GX reported: a float, an integer, text, or a list
%%%                  or map of those; booleans travel as 1/0
%%%     observed_at  epoch ms, when this service received it
%%%
%%% One topic for every reading. The device and the path are in the payload,
%%% not the topic name: a consumer subscribes once and filters.
-module(mcl_victron_facts).

-export([reading_recorded/1, to_wire/1,
         topic/2, realm_name/0, check_realm_name/0, check_realm_name/2]).

-define(ORG, <<"mcl-victron">>).
-define(VERSION, 1).
-define(FIELDS, [portal_id, service, instance, dbus_path, value, observed_at]).

%% @doc The fact for a recorded event, whose keys may be atoms or binaries
%% (an event read back from the store is binary-keyed).
-spec reading_recorded(map()) -> map().
reading_recorded(Event) ->
    maps:from_list([{Field, field(Field, Event)} || Field <- ?FIELDS]).

field(Field, Event) ->
    maps:get(Field, Event, maps:get(atom_to_binary(Field, utf8), Event, undefined)).

%% @doc Text as CBOR text, booleans as 1/0, numbers as they are.
-spec to_wire(term()) -> term().
to_wire(B) when is_binary(B) -> {text, B};
to_wire(true) -> 1;
to_wire(false) -> 0;
to_wire(L) when is_list(L) -> [to_wire(E) || E <- L];
to_wire(M) when is_map(M) -> maps:map(fun(_K, V) -> to_wire(V) end, M);
to_wire(Other) -> Other.

-spec topic(binary(), reading_recorded) -> binary().
topic(RealmName, reading_recorded) ->
    macula_topic:app_fact(RealmName, ?ORG, <<"victron">>, <<"energy">>,
                          <<"reading_recorded">>, ?VERSION).

%% @doc Refuse to start when the realm name the topic carries is not the realm
%% the pool is in: every reading would go where nobody listens.
-spec check_realm_name() -> ok.
check_realm_name() ->
    configured(realm_name(), mcl_om:realm()).

configured(Name, {ok, Tag}) -> check_realm_name(Name, Tag);
configured(Name, Other)     -> error({mcl_victron_realm_unset, Name, Other}).

-spec check_realm_name(binary(), binary()) -> ok.
check_realm_name(Name, Tag) ->
    matched(crypto:hash(sha256, Name) =:= Tag, Name, Tag).

matched(true, _Name, _Tag) -> ok;
matched(false, Name, Tag)  -> error({mcl_victron_realm_name_mismatch, Name, Tag}).

-spec realm_name() -> binary().
realm_name() ->
    named(application:get_env(mcl_victron, realm_name, undefined)).

named(Name) when is_list(Name), Name =/= "" -> unicode:characters_to_binary(Name);
named(Name) when is_binary(Name), Name =/= <<>> -> Name;
named(_Unset) -> error({mcl_victron_realm_name_unset, realm_name}).

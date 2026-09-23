%%% @doc Command `record_victron_reading_v1`.
%%%
%%% Carries one notification from a Victron GX into the aggregate.
%%% The payload mirrors the parsed dbus-flashmq topic plus the value
%%% the broker delivered and the local timestamp of observation.
-module(record_victron_reading_v1).
-behaviour(evoq_command).

-export([command_type/0]).
-export([new/1, validate/1, to_map/1]).
-export([stream_id/1]).
-export([
    get_portal_id/1,
    get_service/1,
    get_instance/1,
    get_dbus_path/1,
    get_value/1,
    get_observed_at/1
]).

-record(record_victron_reading_v1, {
    portal_id   :: binary() | undefined,
    service     :: binary() | undefined,
    instance    :: binary() | undefined,
    dbus_path   :: binary() | undefined,
    value       :: term(),
    observed_at :: non_neg_integer() | undefined
}).

-opaque t() :: #record_victron_reading_v1{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> record_victron_reading_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{portal_id := P,
      service := S,
      instance := I,
      dbus_path := D,
      value := V,
      observed_at := T} = _Params)
  when is_binary(P), is_binary(S), is_binary(I),
       is_binary(D), is_integer(T) ->
    {ok, #record_victron_reading_v1{
        portal_id   = P,
        service     = S,
        instance    = I,
        dbus_path   = D,
        value       = V,
        observed_at = T
    }};
new(_) ->
    {error, invalid_params}.

-spec validate(t()) -> ok | {error, term()}.
validate(#record_victron_reading_v1{portal_id   = P,
                                    service     = S,
                                    instance    = I,
                                    dbus_path   = D,
                                    observed_at = T})
  when is_binary(P), P =/= <<>>,
       is_binary(S), S =/= <<>>,
       is_binary(I), I =/= <<>>,
       is_binary(D), D =/= <<>>,
       is_integer(T), T >= 0 ->
    ok;
validate(_) ->
    {error, invalid_command}.

-spec to_map(t()) -> map().
to_map(#record_victron_reading_v1{} = Cmd) ->
    #{
        command_type => record_victron_reading_v1,
        portal_id    => Cmd#record_victron_reading_v1.portal_id,
        service      => Cmd#record_victron_reading_v1.service,
        instance     => Cmd#record_victron_reading_v1.instance,
        dbus_path    => Cmd#record_victron_reading_v1.dbus_path,
        value        => Cmd#record_victron_reading_v1.value,
        observed_at  => Cmd#record_victron_reading_v1.observed_at
    }.

%% Stream is per-Cerbo (per portal-id).
-spec stream_id(t()) -> binary().
stream_id(#record_victron_reading_v1{portal_id = P}) ->
    victron_device_aggregate:stream_id(P).

-spec get_portal_id(t()) -> binary().
get_portal_id(#record_victron_reading_v1{portal_id = V})   -> V.
-spec get_service(t()) -> binary().
get_service(#record_victron_reading_v1{service = V})       -> V.
-spec get_instance(t()) -> binary().
get_instance(#record_victron_reading_v1{instance = V})     -> V.
-spec get_dbus_path(t()) -> binary().
get_dbus_path(#record_victron_reading_v1{dbus_path = V})   -> V.
-spec get_value(t()) -> term().
get_value(#record_victron_reading_v1{value = V})           -> V.
-spec get_observed_at(t()) -> non_neg_integer().
get_observed_at(#record_victron_reading_v1{observed_at = V}) -> V.

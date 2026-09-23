%%% @doc Event `victron_reading_recorded_v1`.
%%%
%%% Domain event produced by `maybe_record_victron_reading` from a
%%% `record_victron_reading_v1' command. Carries the same shape as the
%%% command — internal-domain event, not a mesh integration fact. The
%%% emitter slice
%%% (`on_victron_reading_recorded_to_mesh`) is what eventually
%%% translates this into a public fact.
-module(victron_reading_recorded_v1).
-behaviour(evoq_event).

-export([event_type/0]).
-export([new/1, to_map/1]).
-export([
    get_portal_id/1,
    get_service/1,
    get_instance/1,
    get_dbus_path/1,
    get_value/1,
    get_observed_at/1
]).

-record(victron_reading_recorded_v1, {
    portal_id   :: binary() | undefined,
    service     :: binary() | undefined,
    instance    :: binary() | undefined,
    dbus_path   :: binary() | undefined,
    value       :: term(),
    observed_at :: non_neg_integer() | undefined
}).

-opaque t() :: #victron_reading_recorded_v1{}.
-export_type([t/0]).

event_type() -> victron_reading_recorded_v1.

-spec new(map()) -> {ok, t()}.
new(#{portal_id := P,
      service := S,
      instance := I,
      dbus_path := D,
      value := V,
      observed_at := T} = _Params) ->
    {ok, #victron_reading_recorded_v1{
        portal_id   = P,
        service     = S,
        instance    = I,
        dbus_path   = D,
        value       = V,
        observed_at = T
    }}.

-spec to_map(t()) -> map().
to_map(#victron_reading_recorded_v1{} = Ev) ->
    #{
        event_type   => victron_reading_recorded_v1,
        portal_id    => Ev#victron_reading_recorded_v1.portal_id,
        service      => Ev#victron_reading_recorded_v1.service,
        instance     => Ev#victron_reading_recorded_v1.instance,
        dbus_path    => Ev#victron_reading_recorded_v1.dbus_path,
        value        => Ev#victron_reading_recorded_v1.value,
        observed_at  => Ev#victron_reading_recorded_v1.observed_at
    }.

-spec get_portal_id(t()) -> binary().
get_portal_id(#victron_reading_recorded_v1{portal_id = V})     -> V.
-spec get_service(t()) -> binary().
get_service(#victron_reading_recorded_v1{service = V})         -> V.
-spec get_instance(t()) -> binary().
get_instance(#victron_reading_recorded_v1{instance = V})       -> V.
-spec get_dbus_path(t()) -> binary().
get_dbus_path(#victron_reading_recorded_v1{dbus_path = V})     -> V.
-spec get_value(t()) -> term().
get_value(#victron_reading_recorded_v1{value = V})             -> V.
-spec get_observed_at(t()) -> non_neg_integer().
get_observed_at(#victron_reading_recorded_v1{observed_at = V}) -> V.

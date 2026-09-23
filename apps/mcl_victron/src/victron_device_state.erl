%%% @doc State of the victron_device aggregate: one per GX device, on the
%%% stream victron_device_aggregate:stream_id/1 derives from its portal id.
%%%
%%% It carries how many readings the device has recorded and when the latest
%%% was observed. There is no business rule on it: every well-formed reading
%%% is recorded. Per-channel last values belong to a read model, not here.
-module(victron_device_state).
-behaviour(evoq_state).

-export([new/1, apply_event/2, to_map/1, from_map/1]).

-record(state, {
    portal_id :: binary() | undefined,
    readings_count = 0 :: non_neg_integer(),
    last_observed_at = 0 :: non_neg_integer()
}).

-type state() :: #state{}.
-export_type([state/0]).

%% The stream id is a digest: the portal id comes from the events.
-spec new(binary()) -> state().
new(_StreamId) -> #state{}.

%% The one event this aggregate records. Its keys are atoms whether it is
%% applied right after execute or replayed; the binary form is read too, for a
%% snapshot or event written by another producer.
-spec apply_event(state(), map()) -> state().
apply_event(#state{readings_count = N, last_observed_at = Last} = S, Event) ->
    S#state{portal_id = field(portal_id, Event),
            readings_count = N + 1,
            last_observed_at = max(Last, observed_at(Event))}.

field(Key, Event) ->
    maps:get(Key, Event, maps:get(atom_to_binary(Key, utf8), Event, undefined)).

observed_at(#{observed_at := T}) when is_integer(T)       -> T;
observed_at(#{<<"observed_at">> := T}) when is_integer(T) -> T;
observed_at(_Event)                                       -> 0.

-spec from_map(map()) -> {ok, state()} | {error, term()}.
from_map(#{portal_id := P, readings_count := N, last_observed_at := T}) ->
    {ok, #state{portal_id = P, readings_count = N, last_observed_at = T}};
from_map(Other) ->
    {error, {not_a_device_state, Other}}.

-spec to_map(state()) -> map().
to_map(#state{portal_id = P, readings_count = N, last_observed_at = T}) ->
    #{portal_id => P, readings_count => N, last_observed_at => T}.

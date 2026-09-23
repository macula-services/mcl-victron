%%% @doc Aggregate root for a single Victron GX device.
%%%
%%% One stream per Cerbo, derived from the VRM portal id. The aggregate
%%% has no enforced business rules in v0.1 — every well-formed
%%% reading is recorded — but it gives every event a coherent stream
%%% identity and an ordering boundary, which is what reckon-db needs.
-module(victron_device_aggregate).
-behaviour(evoq_aggregate).

-export([init/1, execute/2, apply/2]).
-export([state_module/0, stream_id/1, snapshot/1, from_snapshot/1]).

-spec state_module() -> module().
state_module() -> victron_device_state.

%% @doc The device's stream: `victron-' and the first 128 bits of
%% sha256(portal id), in hex. reckon-gater accepts a user stream only as
%% `[a-z]{1,32}-[a-f0-9]{32}', so the portal id cannot be the suffix itself.
-spec stream_id(binary()) -> binary().
stream_id(PortalId) when is_binary(PortalId) ->
    <<Digest:16/binary, _/binary>> = crypto:hash(sha256, PortalId),
    <<"victron-", (binary:encode_hex(Digest, lowercase))/binary>>.

init(AggregateId) ->
    {ok, victron_device_state:new(AggregateId)}.

%% evoq calls execute(State, Payload) — State FIRST. Demon 10.
execute(_State, #{command_type := record_victron_reading_v1} = Payload) ->
    maybe_record_victron_reading:handle_from_map(Payload);
execute(_State, _Unknown) ->
    {error, unknown_command}.

apply(State, Event) ->
    victron_device_state:apply_event(State, Event).

%% A device's stream grows for as long as it reports. Snapshots (evoq takes one
%% every 100 events) keep an aggregate's start from replaying all of it.
snapshot(State) -> victron_device_state:to_map(State).

from_snapshot(Map) ->
    {ok, State} = victron_device_state:from_map(Map),
    State.

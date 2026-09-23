%%% @doc Handler for `record_victron_reading_v1'.
%%%
%%% Validates the command shape and produces a matching
%%% `victron_reading_recorded_v1' domain event. The internal event
%%% lives in `mcl_victron_store'; an emitter
%%% (`on_victron_reading_recorded_to_mesh') translates it into an
%%% external integration fact on the mesh. Doctrinal boundary —
%%% commands stay local, mesh facts are explicit.
-module(maybe_record_victron_reading).

-export([handle/1, handle_from_map/1, dispatch/1]).

%% @doc The command's payload as evoq hands it to the aggregate: the map
%% record_victron_reading_v1:to_map/1 made, atom-keyed.
-spec handle_from_map(map()) -> {ok, [map()]} | {error, term()}.
handle_from_map(#{command_type := record_victron_reading_v1} = Payload) ->
    handled(record_victron_reading_v1:new(Payload));
handle_from_map(_) ->
    {error, unknown_command}.

handled({ok, Cmd})         -> handle(Cmd);
handled({error, _} = Error) -> Error.

-spec handle(record_victron_reading_v1:t()) ->
    {ok, [map()]} | {error, term()}.
handle(Cmd) ->
    case record_victron_reading_v1:validate(Cmd) of
        ok ->
            {ok, Event} = victron_reading_recorded_v1:new(#{
                portal_id   => record_victron_reading_v1:get_portal_id(Cmd),
                service     => record_victron_reading_v1:get_service(Cmd),
                instance    => record_victron_reading_v1:get_instance(Cmd),
                dbus_path   => record_victron_reading_v1:get_dbus_path(Cmd),
                value       => record_victron_reading_v1:get_value(Cmd),
                observed_at => record_victron_reading_v1:get_observed_at(Cmd)
            }),
            {ok, [victron_reading_recorded_v1:to_map(Event)]};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Record one reading on its device's stream in `mcl_victron_store'.
%% The caller sees `{error, _}' rather than a success nothing stored.
-spec dispatch(record_victron_reading_v1:t()) ->
    {ok, non_neg_integer(), [map()]} | {error, term()}.
dispatch(Cmd) ->
    EvoqCmd = evoq_command:new(record_victron_reading_v1, victron_device_aggregate,
                               record_victron_reading_v1:stream_id(Cmd),
                               record_victron_reading_v1:to_map(Cmd),
                               #{timestamp => erlang:system_time(millisecond)}),
    evoq_command_router:dispatch(EvoqCmd, #{store_id => mcl_victron_store,
                                            adapter => reckon_evoq_adapter,
                                            consistency => eventual}).

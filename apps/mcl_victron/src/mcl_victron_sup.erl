%%% @doc Top supervisor, started by mcl_victron_service:start/1 once mcl_om has
%%% opened the store.
%%%
%%% Two children, the emitter first so it is registered before the first
%%% reading is recorded: on_victron_reading_recorded_to_mesh, which publishes
%%% each recorded reading, and the receive_victron_mqtt desk, which turns every
%%% dbus-flashmq notification into a record_victron_reading_v1 command.
-module(mcl_victron_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    Children = [
        #{id => on_victron_reading_recorded_to_mesh,
          start => {evoq_event_handler, start_link, [on_victron_reading_recorded_to_mesh, #{}]},
          type => worker,
          modules => [on_victron_reading_recorded_to_mesh]},
        #{id => receive_victron_mqtt_sup,
          start => {receive_victron_mqtt_sup, start_link, []},
          type => supervisor}
    ],
    {ok, {SupFlags, Children}}.

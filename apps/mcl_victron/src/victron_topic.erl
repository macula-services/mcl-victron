%%% @doc Parses dbus-flashmq MQTT notification topics.
%%%
%%% dbus-flashmq topic shape (since Venus OS v3.20):
%%%
%%%   <prefix>/<portal-id>/<service>/<instance>/<dbus-path>
%%%
%%% where:
%%%   prefix    = "N" (notification, broker → client),
%%%               "W" (write request, client → broker), or
%%%               "R" (read request, client → broker)
%%%   portal-id = the Victron VRM portal identifier of the GX device
%%%   service   = service type, e.g. battery, solarcharger, vebus,
%%%               grid, pvinverter, evcharger, tank, gps, system,
%%%               settings, ...
%%%   instance  = device-instance integer, e.g. "0"
%%%   dbus-path = the slash-separated D-Bus path under that service,
%%%               e.g. "Dc/0/Voltage"
-module(victron_topic).

-export([parse_notification/1]).
-export_type([parsed/0]).

-type parsed() :: #{
    prefix    := <<_:8>>,
    portal    := binary(),
    service   := binary(),
    instance  := binary(),
    dbus_path := binary()
}.

%% @doc Parse a notification topic into its components. Returns
%% `error' for any topic that does not match the canonical shape or
%% whose prefix is not `N'.
-spec parse_notification(binary()) -> {ok, parsed()} | error.
parse_notification(Topic) when is_binary(Topic) ->
    case binary:split(Topic, <<"/">>, [global]) of
        [<<"N">>, Portal, Service, Instance | PathSegs] when
              Portal =/= <<>>,
              Service =/= <<>>,
              Instance =/= <<>>,
              PathSegs =/= [] ->
            DbusPath = binary_join(PathSegs, <<"/">>),
            {ok, #{
                prefix    => <<"N">>,
                portal    => Portal,
                service   => Service,
                instance  => Instance,
                dbus_path => DbusPath
            }};
        _ ->
            error
    end;
parse_notification(_) ->
    error.

%%% Internals

binary_join([], _Sep) -> <<>>;
binary_join([B], _Sep) -> B;
binary_join([H | T], Sep) ->
    lists:foldl(
        fun(Part, Acc) -> <<Acc/binary, Sep/binary, Part/binary>> end,
        H,
        T
    ).

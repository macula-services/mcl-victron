%% @doc OTP application entry.
%%
%% mcl_om:boot/1 wires the mesh, the realm identity and health, opens the
%% reckon-db store mcl_victron_service names and its evoq subscription, then
%% starts the service. Ingest starts only after the store exists.
-module(mcl_victron_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) -> mcl_om:boot(mcl_victron_service).

stop(_State) -> ok.

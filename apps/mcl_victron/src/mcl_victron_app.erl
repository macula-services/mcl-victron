%% @doc OTP application entry.
%%
%% Opens this service's own reckon-db store and its evoq subscription
%% (mcl_victron_store, from mcl_victron_service:event_store/0), THEN lets
%% mcl_om:boot/1 wire the mesh, the realm identity and health and start the
%% service. Ingest starts only after the store exists. mcl_om opens no store.
-module(mcl_victron_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    ok = mcl_victron_store:open(mcl_victron_service:event_store()),
    mcl_om:boot(mcl_victron_service).

stop(_State) -> ok.

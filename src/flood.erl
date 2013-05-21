-module(flood).

-export([start/0, stop/0]).

-export([get_env/1]).

-export([spawn_clients/1, spawn_clients/2, kill_clients/1, disconnect_clients/1]).
-export([clients_status/0, clients_status/1, ping/0]).

start() ->
    lager:start(),
    application:start(flood).

stop() ->
    application:stop(flood).

get_env(Key) ->
    {ok, Value} = application:get_env(?MODULE, Key),
    Value.

spawn_clients(Number) ->
    flood_serv:spawn_clients(Number).

spawn_clients(Number, Args) ->
    flood_serv:spawn_clients(Number, Args).

kill_clients(Number) ->
    flood_serv:kill_clients(Number).

disconnect_clients(Number) ->
    flood_serv:disconnect_clients(Number).

clients_status() ->
    flood_serv:clients_status().

clients_status(Strategy) ->
    flood_serv:clients_status(Strategy).

ping() ->
    flood_serv:ping().

-module(flood).

-export([start/0, stop/0]).

-export([get_env/1]).

-export([spawn/1, spawn/2, spawn/4, kill/1, disconnect/1]).
-export([status/0, ping/0]).

start() ->
    crypto:start(), % Used by WebSocket client backend
    ssl:start(),    % To be used by WebSocket client backend
    lager:start(),
    application:start(flood).

stop() ->
    application:stop(flood).

get_env(Key) ->
    {ok, Value} = application:get_env(?MODULE, Key),
    Value.

spawn(Number) ->
    flood_serv:spawn_clients(Number).

spawn(Number, Args) ->
    flood_serv:spawn_clients(Number, Args).

spawn(Number, Max, Interval, Args) ->
    flood_serv:spawn_clients(Number, Max, Interval, Args).

kill(Number) ->
    flood_serv:kill_clients(Number).

disconnect(Number) ->
    flood_serv:disconnect_clients(Number).

status() ->
    flood_serv:clients_status().

ping() ->
    flood_serv:ping().

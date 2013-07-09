-module(flood).

-export([start/0, stop/0]).

-export([get_env/1]).

-export([spawn/1, spawn/2, spawn/4, kill/1, ping/0]).

-export([inc/1, inc/2, dec/1, dec/2, new/1, get/1, stats/0]).

start() ->
    crypto:start(), % Used by WebSocket client backend
    ssl:start(),    % To be used by WebSocket client backend
    lager:start(),
    application:start(folsom),
    init_counters(),
    application:start(flood).

stop() ->
    application:stop(folsom),
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

ping() ->
    flood_serv:ping().

inc(Counter) ->
    inc(Counter, 1).

inc(Counter, Value) ->
    folsom_metrics:notify({Counter, {inc, Value}}).

dec(Counter) ->
    dec(Counter, 1).

dec(Counter, Value) ->
    folsom_metrics:notify({Counter, {dec, Value}}).

new(Counter) ->
    ok = folsom_metrics:new_counter(Counter).

get(Counter) ->
    folsom_metrics:get_metric_value(Counter).

stats() ->
    lists:map(fun(M) -> {M, flood:get(M)} end, folsom_metrics:get_metrics()).

%% Internal functions:
init_counters() ->
    new(disconnected),
    new(connected),
    new(terminated),
    new(all),
    new(alive),
    new(ws_incomming),
    new(ws_outgoing),
    new(http_incomming),
    new(http_outgoing).

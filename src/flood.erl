-module(flood).
-export([start/0, stop/0]).

start() ->
    application:start(flood).

stop() ->
    application:stop(flood).

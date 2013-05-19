-module(floodutils).

-export([log/1, log/2]).

log(Msg) ->
    io:format("~w: ~s\n", [self(), Msg]).

log(Msg, Args) ->
    io:format("~w: " ++ Msg ++ "\n", [self() | Args]).

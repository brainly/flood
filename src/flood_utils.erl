-module(flood_utils).

-export([init/0, log/1, log/2, log/3]).

init() ->
    lager:start().

log(Msg) ->
    log(info, "~w: ~s", [self(), Msg]).

log(Msg, Args) ->
    log(info , "~w: " ++ Msg, [self() | Args]).

%% Valid Levels are: debug, info, warning, error
log(Level, Msg, Args) when is_atom(Level) ->
    lager:info(Msg, Args).

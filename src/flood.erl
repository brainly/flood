-module(flood).
-export([start/0, stop/0]).

-export([get_env/1]).

start() ->
    lager:start(),
    application:start(flood).

stop() ->
    application:stop(flood).

get_env(Key) ->
    {ok, Value} = application:get_env(?MODULE, Key),
    Value.

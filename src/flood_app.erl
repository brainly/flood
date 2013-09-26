-module(flood_app).
-author('kajetan.rzepecki@zadane.pl').
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    flood_pool_sup:start_link(flood:get_env(max_clients)).

stop(_State) ->
    ok.

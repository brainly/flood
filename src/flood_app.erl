-module(flood_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    Limit = flood:get_env(max_clients),
    flood_pool_sup:start_link(Limit, {flood_fsm, start_link, []}).

stop(_State) ->
    ok.

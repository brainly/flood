-module(flood_pool_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).

%% API functions
start_link(ClientLimit) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, {ClientLimit}).

%% Supervisor callbacks
init({ClientLimit}) ->
    Strategy = {one_for_all, 5, 3600},
    Processes = [{flood_serv,
                  {flood_serv, start_link, [ClientLimit, {flood_fsm, start_link, []}, self()]},
                  permanent,
                  10000,
                  worker,
                  [flood_serv]},
                {flood_manager,
                  {flood_manager, start_link, []},
                  permanent,
                  10000,
                  worker,
                  [flood_manager]}],
    {ok, {Strategy, Processes}}.

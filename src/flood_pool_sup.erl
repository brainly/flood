-module(flood_pool_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

%% API functions
start_link(Limit, MFA) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, {Limit, MFA}).

%% Supervisor callbacks

init({Limit, MFA}) ->
    Strategy = {one_for_one, 5, 3600},
    Processes = [make_flood_serv(Limit, MFA, self())],
    {ok, {Strategy, Processes}}.

%% Internal functions

make_flood_serv(Limit, MFA, Supervisor) ->
    {flood_serv, {flood_serv, start_link, [Limit, MFA, Supervisor]},
                 permanent, brutal_kill, worker, [flood_serv]}.

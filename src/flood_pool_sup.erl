-module(flood_pool_sup).
-behaviour(supervisor).

-export([start_link/2, init/1]).

%% API functions
start_link(Limit, MFA) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, {Limit, MFA}).

%% Supervisor callbacks
init({Limit, MFA}) ->
    Strategy = {one_for_all, 5, 3600},
    Processes = [flood_serv_spec(Limit, MFA, self())],
    {ok, {Strategy, Processes}}.

%% Internal functions
flood_serv_spec(Limit, MFA, Supervisor) ->
    {flood_serv,
     {flood_serv, start_link, [Limit, MFA, Supervisor]},
     permanent,
     10000,
     worker,
     [flood_serv]}.

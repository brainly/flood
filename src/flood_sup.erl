-module(flood_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).

-export([spec/1]).

%% API functions
start_link(MFA) ->
    supervisor:start_link(?MODULE, MFA).

%% Supervisor callbacks

init(MFA) ->
    Strategy = {simple_one_for_one, 5, 3600},
    Processes = [child_spec(MFA)],
    {ok, {Strategy, Processes}}.

spec(MFA) ->
    {worker_sup,
     {?MODULE, start_link, [MFA]},
     temporary,
     10000,
     supervisor,
     [?MODULE]}.

child_spec({M, F, A}) ->
    {flood_fsm,
     {M, F, A},
     temporary,
     5000,
     worker,
     [M]}.

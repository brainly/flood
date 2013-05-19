-module(flood_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

%% API functions
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Supervisor callbacks

init([]) ->
    Strategy = {one_for_one, 5, 10},
    Processes = [make_flood_serv("./misc/urls.txt")],
    {ok, {Strategy, Processes}}.

%% Internal functions

make_flood_serv(InitFile) ->
    {flood_serv, {flood_serv, start_link, [InitFile]},
                 permanent, 5000, worker, dynamic}.

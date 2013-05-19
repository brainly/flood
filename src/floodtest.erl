-module(floodtest).
-behaviour(gen_server).

-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_URL, "http://localhost:8080/poll/3").

-export([start_link/1, init/1, terminate/2, handle_call/3, handle_info/2]).

-export([spawn_clients/1, disconnect_clients/1, kill_clients/1, clients_status/0, ping/0]).

%% Gen Server related

start_link(Arg) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Arg, []).

init(Filename) when is_list(Filename) ->
    inets:start(),
    Clients = loadurls(Filename,
                       fun (Url, Timeout) ->
                               floodutils:log("Starting new floodfsm with url: ~s, and timeout: ~w",
                                              [Url, Timeout]),
                               {ok, Pid} = floodfsm:start_link(Url, Timeout),
                               Pid
                       end),
    {ok, Clients};

init(Number) when is_integer(Number)->
    inets:start(),
    %% TODO Would probably need gen_server:cast
    spawn_clients(Number),
    {ok, []}.

terminate(Reason, Clients) ->
    floodutils:log("Server terminated:~s- Clients: ~p~n- Reason: ~w", [Clients, Reason]).

%% External functions

spawn_clients(Number) ->
    try gen_server:call(?MODULE, {spawn_clients, Number}) of
        Reply -> Reply
    catch
        _:_ -> floodutils:log("Error while spawning more clients."),
               error
    end.

disconnect_clients(Number) ->
    try gen_server:call(?MODULE, {disconnect_clients, Number}) of
        Reply -> Reply
    catch
        _:_ -> floodutils:log("Error while disconnecting clients."),
               error
    end.

kill_clients(Number) ->
    try gen_server:call(?MODULE, {kill_clients, Number}) of
        Reply -> Reply
    catch
        _:_ -> floodutils:log("Error while killing clients."),
               error
    end.

clients_status() ->
    try gen_server:call(?MODULE, {clients_status, all}) of
        Reply -> Reply % Returns a tuple of {TotalClients, Connected, Disconnected}
    catch
        _:_ -> floodutils:log("Error while fetching client status."),
               error
    end.

ping() ->
    try gen_server:call(?MODULE, ping) of
        Reply -> Reply
    catch
        _:_ -> floodutils:log("Error while pinging u_u."),
               error
    end.

%% Gen Server handlers

handle_call({spawn_clients, Number}, _, Clients) ->
    NewState = repeat(Number,
                      fun() ->
                              floodutils:log("Starting new floodfsm with url: ~s, and timeout: ~w",
                                             [?DEFAULT_URL, ?DEFAULT_TIMEOUT]),
                              {ok, Pid} = floodfsm:start_link(?DEFAULT_URL, ?DEFAULT_TIMEOUT),
                              Pid
                      end,
                      Clients),
    {reply, ok, NewState};

handle_call({disconnect_clients, Number}, _, Clients) ->
    disconnect_clients(Number, Clients),
    {reply, ok, Clients};

handle_call({kill_clients, Number}, _, Clients) ->
    RestOfClients = kill_clients(Number, Clients),
    {reply, ok, RestOfClients};

handle_call({clients_status, _Strategy}, _, Clients) ->
    %% TODO Use Strategy to distinquish which stats to collect
    Stats = lists:foldl(fun(Client, {Total, Connected, Disconnected}) ->
                                case gen_fsm:sync_send_all_state_event(Client, status) of
                                    connected    -> {Total + 1, Connected + 1, Disconnected};
                                    disconnected -> {Total + 1, Connected, Disconnected + 1}
                                end
                        end,
                        {0, 0, 0},
                        Clients),
    {reply, Stats, Clients};

handle_call(ping, _, State) ->
    {reply, pong, State}.

handle_info(timeout, State) ->
    floodutils:log("Timeout..."),
    {stop, shutdown, State};

handle_info(Info, State) ->
    floodutils:log("Info: ~w", [Info]),
    {noreply, State}.

%% Internal functions

repeat(0, _, Accumulator) ->
    Accumulator;

repeat(Number, Proc, Accumulator) ->
    Result = Proc(),
    repeat(Number - 1, Proc, [Result | Accumulator]).

loadurls(Filename, Callback) when is_function(Callback)->
    for_each_line_in_file(Filename,
                          fun(Url, Timeout, List) ->
                                  Result = Callback(Url, Timeout),
                                  [Result | List]
                          end,
                          [read], []).

for_each_line_in_file(Name, Proc, Mode, Accum) ->
    {ok, Device} = file:open(Name, Mode),
    for_each_line(Device, Proc, Accum).

for_each_line(Device, Proc, Accum) ->
    case io:get_line(Device, "") of
        eof  -> file:close(Device),
                Accum;

        %% TODO Deuglify
        Line -> case string:tokens(string:strip(Line, right, $\n), ";") of
                    %% Timeout present in file
                    [Url, Timeout] ->
                        for_each_line(Device, Proc,
                                      Proc(Url,
                                           try list_to_integer(Timeout) of
                                               Number -> Number
                                           catch
                                               _:_ -> ?DEFAULT_TIMEOUT
                                           end,
                                           Accum));

                    %% No timeout specified in file
                    [Url] ->
                        for_each_line(Device, Proc, Proc(Url, ?DEFAULT_TIMEOUT, Accum))
                end
    end.

kill_clients(0, Rest) ->
    Rest;

kill_clients(_, []) ->
    floodutils:log("Warning: attempting to kill more clients than are started."),
    [];

kill_clients(Number, [Client | Rest]) ->
    gen_fsm:sync_send_all_state_event(Client, terminate),
    kill_clients(Number - 1, Rest).

disconnect_clients(0, _) ->
    ok;

disconnect_clients(_, []) ->
    floodutils:log("Warning: attempting to disconnect more clients than are connected.");

disconnect_clients(Number, [Client | Rest]) ->
    case gen_fsm:sync_send_all_state_event(Client, status) of
        connected    -> floodutils:log("Attempting to disconnect client: ~w", [Client]),
                        gen_fsm:sync_send_all_state_event(Client, disconnect),
                        disconnect_clients(Number-1, Rest);
        disconnected -> disconnect_clients(Number, Rest)
    end.

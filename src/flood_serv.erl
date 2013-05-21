-module(flood_serv).
-behaviour(gen_server).

-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_URL, "http://localhost:8080/poll/3").

-export([start_link/3, init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

-export([spawn_clients/1, spawn_clients/2, disconnect_clients/1, kill_clients/1]).
-export([clients_status/0, clients_status/1, ping/0]).

-record(server_state, {limit = 0, supervisor, clients = gb_test:empty()}).

%% Gen Server related

start_link(Limit, MFA, Supervisor) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {Limit, MFA, Supervisor}, []).

init({Limit, MFA, Supervisor}) ->
    inets:start(),
    self() ! {start_flood_sup, Supervisor, MFA},
    {ok, #server_state{limit = Limit, clients = gb_sets:empty()}}.

terminate(Reason, State) ->
    lager:info("Server terminated:~n- State: ~p~n- Reason: ~w", [State, Reason]),
    ok.

%% External functions
spawn_clients(Filename) when is_list(Filename) ->
    loadurls(Filename,
             fun (Url, Timeout, _Accumulator) ->
                     spawn_clients(1, [Url, Timeout])
             end);

spawn_clients(Number) ->
    spawn_clients(Number, [?DEFAULT_URL, ?DEFAULT_TIMEOUT]).

spawn_clients(Number, []) ->
    spawn_clients(Number, [?DEFAULT_URL, ?DEFAULT_TIMEOUT]);

spawn_clients(Number, [Url]) ->
    spawn_clients(Number, [Url, ?DEFAULT_TIMEOUT]);

spawn_clients(Number, Args) ->
    try gen_server:call(?MODULE, {spawn_clients, Number, Args}) of
        Reply -> Reply
    catch
        _:_ -> lager:error("Error while spawning more clients."),
               error
    end.

disconnect_clients(Number) ->
    try gen_server:call(?MODULE, {disconnect_clients, Number}) of
        Reply -> Reply
    catch
        _:_ -> lager:error("Error while disconnecting clients."),
               error
    end.

kill_clients(Number) ->
    try gen_server:call(?MODULE, {kill_clients, Number}) of
        Reply -> Reply
    catch
        _:_ -> lager:error("Error while killing clients."),
               error
    end.

clients_status() ->
    clients_status(all).

clients_status(Strategy) ->
    try gen_server:call(?MODULE, {clients_status, Strategy}) of
        Reply -> Reply % Returns a tuple of {TotalClients, Connected, Disconnected}
    catch
        _:_ -> lager:error("Error while fetching client status."),
               error
    end.

ping() ->
    try gen_server:call(?MODULE, ping) of
        Reply -> Reply
    catch
        _:_ -> lager:error("Error while pinging u_u."),
               error
    end.

%% Gen Server handlers
handle_call({spawn_clients, _Number, _Args}, _From, State = #server_state{limit = Limit}) when Limit =< 0 ->
    {reply, {error, "Max number of clients reached."}, State};

handle_call({spawn_clients, Number, Args},
            _From,
            State = #server_state{limit = Limit, supervisor = Supervisor, clients = Clients}) ->
    NumNewClients = max(0, min(Number, Limit - Number)),
    NewClients = repeat(NumNewClients,
                        fun(AllClients) ->
                                lager:info("Starting new flood_fsm with url: ~s, and timeout: ~w",
                                           Args),
                                {ok, Pid} = supervisor:start_child(Supervisor, Args),
                                erlang:monitor(process, Pid),
                                Ref = Pid,
                                gb_sets:add(Ref, AllClients)
                        end,
                        Clients),
    {reply, ok, State#server_state{limit = Limit - NumNewClients, clients = NewClients}};

handle_call({disconnect_clients, Number}, _From, State = #server_state{clients = Clients}) ->
    disconnect_clients(Number, gb_sets:next(gb_sets:iterator(Clients))),
    {reply, ok, State};

handle_call({kill_clients, Number}, _From, State = #server_state{clients = Clients}) ->
    kill_clients(Number, gb_sets:next(gb_sets:iterator(Clients))),
    {reply, ok, State};

handle_call({clients_status, Strategy}, _From, State = #server_state{clients = Clients}) ->
    Stats = collect_stats(Clients, Strategy),
    {reply, Stats, State};

handle_call(ping, _From, State) ->
    {reply, pong, State}.

handle_cast(Request, _State) ->
    lager:warning("Unhandled async request: ~w", [Request]),
    undefined.

handle_info(timeout, State) ->
    lager:warning("Timeout..."),
    {stop, shutdown, State};

handle_info({start_flood_sup, Supervisor, MFA}, State) ->
    lager:info("Starting FSMs supervisor..."),
    {ok, Pid} = supervisor:start_child(Supervisor, flood_sup:spec(MFA)),
    link(Pid),                     % Link the FSM supervisor
    process_flag(trap_exit, true), % Make sure we handle it dieing first.
    lager:info("FSMs supervisor started!"),
    {noreply, State#server_state{supervisor = Pid}};

handle_info({'DOWN', _Ref, process, Pid, Reason},
            State = #server_state{limit = Limit, clients = Clients}) ->
    lager:info("Removing terminated FSM: ~w", [{Pid, Reason}]),
    case gb_sets:is_element(Pid, Clients) of
        true  -> {noreply, State#server_state{limit = Limit + 1, clients = gb_sets:delete(Pid, Clients)}};
        false -> {noreply, State}
    end;

handle_info({'EXIT', Pid, Reason}, State) ->
    lager:warning("Received 'EXIT' message: ~w from: ~w", [Reason, Pid]),
    {noreply, State};

handle_info(Info, State) ->
    lager:warning("Unhandled info message: ~w", [Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    lager:warning("Unhandled code change."),
    {ok, State}.

%% Internal functions

repeat(0, _Proc, Accumulator) ->
    Accumulator;

repeat(Number, Proc, Accumulator) ->
    NewAccumulator = Proc(Accumulator),
    repeat(Number - 1, Proc, NewAccumulator).

loadurls(Filename, Callback) when is_function(Callback)->
    for_each_line_in_file(Filename, Callback, [read], []).

for_each_line_in_file(Name, Callback, Mode, Accum) ->
    {ok, Device} = file:open(Name, Mode),
    for_each_line(Device, Callback, Accum).

for_each_line(Device, Callback, Accum) ->
    case io:get_line(Device, "") of
        eof  -> file:close(Device),
                Accum;

        %% TODO Deuglify
        Line -> case string:tokens(string:strip(Line, right, $\n), ";") of
                    %% Timeout present in file
                    [Url, Timeout] ->
                        for_each_line(Device, Callback,
                                      Callback(Url,
                                               try list_to_integer(Timeout) of
                                                   Number -> Number
                                               catch
                                                   _:_ -> ?DEFAULT_TIMEOUT
                                               end,
                                               Accum));

                    %% No timeout specified in file
                    [Url] ->
                        for_each_line(Device, Callback, Callback(Url, ?DEFAULT_TIMEOUT, Accum))
                end
    end.

kill_clients(0, _Rest) ->
    _Rest;

kill_clients(_Number, none) ->
    lager:warning("Attempting to kill more clients than are started."),
    gb_sets:empty();

kill_clients(Number, {Client, Rest}) ->
    flood_fsm:send_event(Client, terminate),
    kill_clients(Number - 1, gb_sets:next(Rest)).

disconnect_clients(0, _Clients) ->
    ok;

disconnect_clients(_Number, none) ->
    lager:warning("Attempting to disconnect more clients than are connected.");

disconnect_clients(Number, {Client, Rest}) ->
    case flood_fsm:send_event(Client, status) of
        connected    -> lager:info("Attempting to disconnect client: ~w", [Client]),
                        flood_fsm:send_event(Client, disconnect),
                        disconnect_clients(Number-1, gb_sets:next(Rest));
        disconnected -> disconnect_clients(Number, gb_sets:next(Rest))
    end.

collect_stats(Clients, Strategy) ->
    Stats = gb_sets:fold(fun(Client, {Total, Connected, Disconnected}) ->
                                 case flood_fsm:send_event(Client, status) of
                                     connected    -> {Total + 1, Connected + 1, Disconnected};
                                     disconnected -> {Total + 1, Connected, Disconnected + 1}
                                 end
                         end,
                         {0, 0, 0},
                         Clients),

    {Total, Connected, Disconnected} = Stats,

    case Strategy of
        all          -> Stats;
        total        -> Total;
        connected    -> Connected;
        disconnected -> Disconnected;
        _            -> lager:warning("Unknown client status strategy: ~w", [Strategy]),
                        Stats
    end.

-module(flood_serv).
-behaviour(gen_server).

-export([start_link/3, init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

-export([spawn_clients/3]).
-export([kill_clients/1, clients_status/0]).

-record(server_state, {limit = 0, supervisor, clients = gb_sets:empty()}).

%% Gen Server related
start_link(Limit, MFA, PoolSupervisor) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {Limit, MFA, PoolSupervisor}, []).

init({Limit, MFA, PoolSupervisor}) ->
    inets:start(),
    gen_server:cast(?MODULE, {start_flood_sup, PoolSupervisor, MFA}),
    {ok, #server_state{limit = Limit}}.

terminate(Reason, State) ->
    lager:info("Server terminated:~n- State: ~p~n- Reason: ~p", [State, Reason]),
    ok.

%% External functions
spawn_clients(Number, Url, Session) ->
    gen_server:call(?MODULE, {spawn_clients, Number, [Url, Session]}).

%% Kills a Number of clients
kill_clients(Number) ->
    gen_server:cast(?MODULE, {kill_clients, Number}).

%% Returns a tuple of {TotalClients, Connected, Disconnected}
clients_status() ->
    gen_server:call(?MODULE, clients_status).

%% Gen Server handlers
handle_call(Call = {spawn_clients, _Number, _Args}, _From, State) ->
    %% Informs the caller in case of reaching the running clients limit...
    %% ...or proceeds spawning them asynchronously.
    case State#server_state.limit =< 0 of
        true  -> {reply, {error, "Max number of clients reached."}, State};
        false -> gen_server:cast(?MODULE, Call),
                 {reply, ok, State}
    end;

handle_call(clients_status, _From, State) ->
    Stats = do_collect_stats(State#server_state.clients),
    {reply, Stats, State};

handle_call(ping, _From, State) ->
    {reply, pong, State}.

handle_cast({spawn_clients, Number, Args}, State) ->
    #server_state{limit = Limit, supervisor = Supervisor, clients = Clients} = State,
    NumNewClients = max(0, min(Number, Limit)),
    case NumNewClients of
        Number -> lager:info("Spawning ~p new clients...", [Number]);
        _      -> lager:warning("Unable to spawn ~p clients due reaching a limit, spawning only ~p...",
                                [Number, NumNewClients])
    end,
    NewClients = do_spawn_clients(NumNewClients, Supervisor, Args, Clients),

    [{Host, Port, _Endpoint} | _Rest] = Args,
    ibrowse:set_max_sessions(Host, Port, Limit),  %% NOTE Make sure we don't have any problems with the connections.
    {noreply, State#server_state{limit = Limit - NumNewClients, clients = NewClients}};

handle_cast({disconnect_clients, Number}, State) ->
    do_disconnect_clients(Number, gb_sets:next(gb_sets:iterator(State#server_state.clients))),
    {noreply, State};

handle_cast({kill_clients, Number}, State) ->
    do_kill_clients(Number, gb_sets:next(gb_sets:iterator(State#server_state.clients))),
    %% ?MODULE:handle_info/2 takes care of removing killed clients from Clients.
    {noreply, State};

handle_cast({start_flood_sup, PoolSupervisor, MFA}, State) ->
    lager:info("Starting FSMs supervisor..."),
    case supervisor:start_child(PoolSupervisor, flood_sup:spec(MFA)) of
        {ok, Pid} ->
            lager:info("FSMs supervisor started!"),
            {noreply, State#server_state{supervisor = Pid}};
        %% This happens when the pool supervisor has already restarted the FSMs supervisor.
        {error, {already_started, Pid}} ->
            lager:info("FSMs supervisor already started!"),
            {noreply, State#server_state{supervisor = Pid}};
        _ -> lager:info("Cannot start FSMs supervisor!"),
             {stop, shutdown, State}
    end.

handle_info({'DOWN', _Ref, process, Pid, Reason}, State) ->
    lager:info("Removing terminated FSM: ~p", [{Pid, Reason}]),
    #server_state{limit = Limit, clients = Clients} = State,
    case gb_sets:is_element(Pid, Clients) of
        true  -> {noreply, State#server_state{limit = Limit + 1, clients = gb_sets:delete(Pid, Clients)}};
        false -> {noreply, State}
    end;

handle_info(Info, State) ->
    lager:warning("Unhandled info message: ~p", [Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    lager:warning("Unhandled code change."),
    {ok, State}.

%% Internal functions
do_spawn_clients(Number, Supervisor, Args, Clients) ->
    repeat(Number,
           fun(AllClients) ->
                   lager:info("Starting new flood_fsm with config: ~p", [Args]),
                   {ok, Pid} = supervisor:start_child(Supervisor, Args),
                   erlang:monitor(process, Pid),
                   gb_sets:add(Pid, AllClients)
           end,
           Clients).

do_kill_clients(0, _Rest) ->
    ok;

do_kill_clients(_Number, none) ->
    lager:warning("Attempting to kill more clients than are started."),
    ok;

do_kill_clients(Number, {Client, Rest}) ->
    flood_fsm:kill(Client),
    do_kill_clients(Number - 1, gb_sets:next(Rest)).

do_disconnect_clients(0, _Clients) ->
    ok;

do_disconnect_clients(_Number, none) ->
    lager:warning("Attempting to disconnect more clients than are connected.");

do_disconnect_clients(Number, {Client, Rest}) ->
    case flood_fsm:status(Client) of
        connected    -> lager:info("Attempting to disconnect client: ~p", [Client]),
                        flood_fsm:disconnect(Client),
                        do_disconnect_clients(Number-1, gb_sets:next(Rest));
        disconnected -> do_disconnect_clients(Number, gb_sets:next(Rest))
    end.

do_collect_stats(Clients) ->
    gb_sets:fold(fun(Client, {Total, Connected, Disconnected}) ->
                         case flood_fsm:status(Client) of
                             connected    -> {Total + 1, Connected + 1, Disconnected};
                             disconnected -> {Total + 1, Connected, Disconnected + 1}
                         end
                 end,
                 {0, 0, 0},
                 Clients).

%% Utility functions
repeat(0, _Proc, Accumulator) ->
    Accumulator;

repeat(Number, Proc, Accumulator) ->
    NewAccumulator = Proc(Accumulator),
    repeat(Number - 1, Proc, NewAccumulator).

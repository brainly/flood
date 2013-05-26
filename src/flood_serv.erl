-module(flood_serv).
-behaviour(gen_server).

-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_URL, "http://localhost:8080/poll/3").

-export([start_link/3, init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

-export([spawn_clients/1, spawn_clients/2, disconnect_clients/1, kill_clients/1]).
-export([clients_status/0, ping/0]).

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
%% Spawns some clients using default URLs and timeouts or reading them from a file.
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
    gen_server:call(?MODULE, {spawn_clients, Number, Args}).

%% Disconnects a Number of clients
disconnect_clients(Number) ->
    gen_server:cast(?MODULE, {disconnect_clients, Number}).

%% Kills a Number of clients
kill_clients(Number) ->
    gen_server:cast(?MODULE, {kill_clients, Number}).

%% Returns a tuple of {TotalClients, Connected, Disconnected}
clients_status() ->
    gen_server:call(?MODULE, clients_status).

ping() ->
    gen_server:call(?MODULE, ping).

%% Gen Server handlers
handle_call({spawn_clients, _Number, _Args},
            _From,
            State = #server_state{limit = Limit}) when Limit =< 0 ->
    %% Informs the caller in case of reaching the running clients limit...
    {reply, {error, "Max number of clients reached."}, State};

handle_call(Call = {spawn_clients, _Number, _Args}, _From, State) ->
    %% ...or proceeds spawning them asynchronously.
    gen_server:cast(?MODULE, Call),
    {reply, ok, State};

handle_call(clients_status, _From, State = #server_state{clients = Clients}) ->
    Stats = collect_stats(Clients),
    {reply, Stats, State};

handle_call(ping, _From, State) ->
    {reply, pong, State}.

handle_cast({spawn_clients, Number, Args},
            State = #server_state{limit = Limit, supervisor = Supervisor, clients = Clients}) ->
    NumNewClients = max(0, min(Number, Limit - Number)),
    case NumNewClients of
         Number -> lager:info("Spawning ~p new clients...", [Number]);
         _      -> lager:warning("Unable to spawn ~p clients due reaching a limit, spawning only ~p...",
                                 [Number, NumNewClients])
    end,
    NewClients = repeat(NumNewClients,
                        fun(AllClients) ->
                                lager:info("Starting new flood_fsm with url: ~p, and timeout: ~p", Args),
                                {ok, Pid} = supervisor:start_child(Supervisor, Args),
                                erlang:monitor(process, Pid),
                                gb_sets:add(Pid, AllClients)
                        end,
                        Clients),
    {noreply, State#server_state{limit = Limit - NumNewClients, clients = NewClients}};

handle_cast({disconnect_clients, Number}, State = #server_state{clients = Clients}) ->
    disconnect_clients(Number, gb_sets:next(gb_sets:iterator(Clients))),
    {noreply, State};

handle_cast({kill_clients, Number}, State = #server_state{clients = Clients}) ->
    kill_clients(Number, gb_sets:next(gb_sets:iterator(Clients))),
    %% ?MODULE:handle_info/2 takes care of removing killed clients from Clients.
    {noreply, State};

handle_cast({start_flood_sup, PoolSupervisor, MFA}, State) ->
    lager:info("Starting FSMs supervisor..."),
    case supervisor:start_child(PoolSupervisor, flood_sup:spec(MFA)) of
        {ok, Pid} ->
            lager:info("FSMs supervisor started!"),
            {noreply, State#server_state{supervisor = Pid}};
        {error, {already_started, Pid}} ->
            lager:info("FSMs supervisor already started!"),
            {noreply, State#server_state{supervisor = Pid}};
        _ -> lager:info("Cannot start FSMs supervisor!"),
             {stop, shutdown, State}
    end.

handle_info({'DOWN', _Ref, process, Pid, Reason},
            State = #server_state{limit = Limit, clients = Clients}) ->
    lager:info("Removing terminated FSM: ~p", [{Pid, Reason}]),
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
        connected    -> lager:info("Attempting to disconnect client: ~p", [Client]),
                        flood_fsm:send_event(Client, disconnect),
                        disconnect_clients(Number-1, gb_sets:next(Rest));
        disconnected -> disconnect_clients(Number, gb_sets:next(Rest))
    end.

collect_stats(Clients) ->
    gb_sets:fold(fun(Client, {Total, Connected, Disconnected}) ->
                         case flood_fsm:send_event(Client, status) of
                             connected    -> {Total + 1, Connected + 1, Disconnected};
                             disconnected -> {Total + 1, Connected, Disconnected + 1}
                         end
                 end,
                 {0, 0, 0},
                 Clients).

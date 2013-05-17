-module(floodtest).
-behaviour(gen_server).

-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_URL, "http://localhost:8080/poll/3").
-define(DEFAULT_WAIT_TIME, 1000).

-export([start_link/1, init/1, terminate/2]).

-export([spawn_clients/1, kill_clients/1, clients_status/0, ping/0]).

%% Gen Server related

start_link(Arg) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Arg, []).

init(Filename) when is_list(Filename) ->
    inets:start(),
    Clients = loadurls(Filename,
                       fun (Url, Timeout) ->
                               log("Starting new floodfsm with url: ~w, and timeout: ~w",
                                   [Url, Timeout]),
                               floodfsm:start_link(Url, Timeout)
                       end,
                       ?DEFAULT_WAIT_TIME),
    {ok, Clients};

init(Number) when is_integer(Number)->
    inets:start(),
    Clients = repeat(Number,
                     fun() ->
                             log("Starting new floodfsm with url: ~w, and timeout: ~w",
                                 [?DEFAULT_URL, ?DEFAULT_TIMEOUT]),
                             floodfsm:start_link(?DEFAULT_URL, ?DEFAULT_TIMEOUT)
                     end,
                     ?DEFAULT_WAIT_TIME),
    {ok, Clients}.

terminate(Reason, State) ->
    log("State: ~w - ~w", [State, Reason]).

%% External functions

spawn_clients(Number) ->
    try gen_server:call(?MODULE, {spawn_clients, Number}) of
        Reply -> Reply
    catch
        _:_ -> log("Error while spawning more clients."),
               error
    end.

kill_clients(Number) ->
    try gen_server:call(?MODULE, {kill_clients, Number}) of
        Reply -> Reply
    catch
        _:_ -> log("Error while killing clients."),
               error
    end.

clients_status() ->
    try gen_server:call(?MODULE, {clients_status, all}) of
        Reply -> Reply
    catch
        _:_ -> log("Error while fetching client status."),
               error
    end.

ping() ->
    try gen_server:call(?MODULE, ping) of
        Reply -> Reply
    catch
        _:_ -> log("Error while pinging u_u."),
               error
    end.

%% Gen Server handlers

handle_call({spawn_clients, Number}, From, State) ->
    %% TODO Loop and create some more clients
    {reply, ok, State};

handle_call({kill_clients, Number}, From, State) ->
    %% TODO Loop and kill Number active clients.
    {reply, ok, State};

handle_call({clients_status, Strategy}, From, State) ->
    %% TODO Loop and collect clients status.
    {reply, ok, State};

handle_call(ping, From, State) ->
    {reply, pong, State}.

%% Utils

log(Msg) ->
    io:format("~w: ~s\n", [self(), Msg]).

log(Msg, Args) ->
    io:format("~w: " ++ Msg ++ "\n", [self() | Args]).

repeat(Number, Callback, Wait) when is_function(Callback) ->
    repeat_loop(Number,
                fun(Accumulator) ->
                        Result = Callback(),
                        receive
                        after Wait -> ok
                        end,
                        [Result | Accumulator]
                end,
                []).

repeat_loop(0, Proc, Accumulator) ->
    Accumulator;

repeat_loop(Number, Proc, Accumulator) ->
    NewAccumulator = Proc(Accumulator),
    repeat_loop(Number - 1, Proc, NewAccumulator).

loadurls(Filename, Callback, Wait) when is_function(Callback)->
    for_each_line_in_file(Filename,
                          fun(Url, Timeout, List) ->
                                  Result = Callback(Url, Timeout),
                                  receive
                                  after Wait -> ok
                                  end,
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

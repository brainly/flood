-module(floodfsm).
-behaviour(gen_fsm).

-export([start_link/2, init/1, terminate/3]).
-export([try_connect/2, connected/2, disconnected/2, handle_info/3]).

start_link(Url, Timeout) ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, {Timeout*1000, Url}, []).

init({Timeout, Url}) ->
    inets:start(),
    spawn(?MODULE, try_connect, [Timeout, Url]),
    {ok, disconnected, Url}.

terminate(Reason, State, Data) ->
    io:format("State: ~w  (~w) - ~w", [State, Data, Reason]).

connected(Event, Url) ->
    case Event of
        {disconnect, Url} -> io:format("Disconnecting...\n"),
                             io:format("Disconnected!\n"),
                             continue(disconnected, Url);
        _                 -> continue(connected, Url)
    end.

disconnected(Event, Url) ->
    case Event of
        {connect, Url} -> io:format("Connecting...\n"),
                          httpc:request(get, {Url, []}, [], [{sync, false},
                                                             {stream, self},
                                                             {body_format, binary}]),
                          io:format("Connected!\n"),
                          continue(connected, Url);
        _              -> continue(disconnected, Url)
    end.

handle_info(Info, State, Url) ->
    case Info of
        {http, {_Ref, stream_start, _X}} -> continue(State, Url);
        {http, {_Ref, stream, _X}}       -> io:format("Received chunk of data!\n"),
                                            continue(State, Url);
        {http, {_Ref, stream_end, _X}}   -> io:format("End of stream.\n"),
                                            disconnect(Url),
                                            continue(State, Url);
        {http, {_Ref, {error, Why}}}     -> io:format("Connection closed: ~w\n", [Why]),
                                            disconnect(Url),
                                            continue(State, Url)
    end.

try_connect(Timeout, Url) ->
    receive
    after Timeout -> connect(Url)
    end,
    try_connect(Timeout, Url).

connect(Url) ->
    gen_fsm:send_event(?MODULE, {connect, Url}).

disconnect(Url) ->
    gen_fsm:send_event(?MODULE, {disconnect, Url}).

continue(State, Url) ->
    {next_state, State, Url}.

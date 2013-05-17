-module(floodfsm).
-behaviour(gen_fsm).

-export([start_link/2, init/1, terminate/3]).
-export([connected/2, connected/3, disconnected/2, disconnected/3]).
-export([handle_info/3, handle_sync_event/4]).

%% Gen Server related

start_link(Url, Timeout) ->
    gen_fsm:start_link(?MODULE, {Timeout, Url}, []).

init(Data) ->
    connect(Data),
    {ok, disconnected, Data}.

terminate(Reason, State, Data) ->
    log("State: ~w  (~w) - ~w", [State, Data, Reason]).

%% FSM event handlers

connected(Event, _, Data) ->
    %% TODO
    connected(Event, Data).

connected(Event, Data) ->
    case Event of
        {disconnect, NewData} ->
            log("Disconnecting..."), % Transition to disconnected state and make sure
            disconnect(NewData),     % it handles attempts to reconnect.
            log("Disconnected!"),
            continue(disconnected, NewData);
        _ ->
            continue(connected, Data)
    end.

disconnected(Event, _, Data) ->
    %% TODO
    disconnected(Event, Data).

disconnected(Event, Data = {Timeout, _}) ->
    case Event of
        {connect, NewData = {_, NewUrl}} ->
            log("Connecting..."),
            httpc:request(get, {NewUrl, []}, [], [{sync, false},
                                                  {stream, self},
                                                  {body_format, binary}]),
            log("Connected!"),
            continue(connected, NewData);
        _ ->
            log("Attempting to reconnect..."),
            connect(Data, Timeout),
            continue(disconnected, Data)
    end.

handle_info(Info, State, Data) ->
    case Info of
        {http, {_Ref, stream_start, _X}} ->
            continue(State, Data);
        {http, {_Ref, stream, _X}} ->
            log("Received chunk of data!"),
            continue(State, Data);
        {http, {_Ref, stream_end, _X}} ->
            log("End of stream, disconnecting..."),
            disconnect(Data),
            continue(State, Data);
        {http, {_Ref, {error, Why}}} ->
            log("Connection closed: ~w", [Why]),
            disconnect(Data),
            continue(State, Data)
    end.

handle_sync_event(Event, _, State, Data) ->
    %% TODO Move these to Module:StateName/3
    case Event of
        status       -> reply(State, State, Data);
        disconnect   -> disconnect(Data),
                        reply(State, State, Data)
    end.

%% Internal functions

connect(Data) ->
    gen_fsm:send_event(self(), {connect, Data}).

connect(Data, After) ->
    gen_fsm:send_event_after(After, {connect, Data}).

disconnect(Data) ->
    gen_fsm:send_event(self(), {disconnect, Data}).

continue(State, Data) ->
    {next_state, State, Data}.

reply(Reply, State, Data) ->
    {reply, Reply, State, Data}.

%% Utilities
log(Msg) ->
    io:format("~w: ~s\n", [self(), Msg]).

log(Msg, Args) ->
    io:format("~w: " ++ Msg ++ "\n", [self() | Args]).

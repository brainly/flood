-module(flood_fsm).
-behaviour(gen_fsm).

-export([start_link/2, init/1, terminate/3]).
-export([connected/2, connected/3, disconnected/2, disconnected/3]).
-export([handle_info/3, handle_sync_event/4]).

-record(fsm_data, {timeout, url, request_id}).

%% Gen Server related

start_link(Url, Timeout) ->
    gen_fsm:start_link(?MODULE, #fsm_data{timeout=Timeout, url=Url}, []).

init(Data) ->
    connect(Data),
    {ok, disconnected, Data}.

terminate(Reason, State, Data = #fsm_data{request_id = undefined}) ->
    flood_utils:log("FSM terminated:~n- State: ~w~n- Data: ~p~n- Reason: ~w", [State, Data, Reason]);

terminate(Reason, State, Data = #fsm_data{request_id = RequestId}) ->
    flood_utils:log("Cancelling an ongoing request ~w...", [RequestId]),
    httpc:cancel_request(RequestId),
    flood_utils:log("FSM terminated:~n- State: ~w~n- Data: ~p~n- Reason: ~w", [State, Data, Reason]).

%% FSM event handlers

connected(Event, _, Data) ->
    %% TODO Use this instead of handle_sync_event
    connected(Event, Data).

connected(Event, Data) ->
    case Event of
        {disconnect, NewData} ->
            flood_utils:log("Disconnecting..."), % Transition to disconnected state and make sure
            disconnect(NewData),                 % it handles attempts to reconnect.
            flood_utils:log("Disconnected!"),
            continue(disconnected, NewData);
        {terminate, LastData} ->
            flood_utils:log("Terminating..."),
            shutdown(LastData);
        _ ->
            continue(connected, Data)
    end.

disconnected(Event, _, Data) ->
    %% TODO Use this instead of handle_sync_event
    disconnected(Event, Data).

disconnected(Event, Data = #fsm_data{timeout = Timeout}) ->
    case Event of
        {connect, NewData = #fsm_data{url = NewUrl}} ->
            flood_utils:log("Connecting..."),
            {ok, RequestId} = httpc:request(get, {NewUrl, []}, [], [{sync, false},
                                                                    {stream, self},
                                                                    {body_format, binary}]),
            flood_utils:log("Connected!"),
            continue(connected, NewData#fsm_data{request_id = RequestId});
        {terminate, LastData} ->
            flood_utils:log("Terminating..."),
            shutdown(LastData);
        _ ->
            flood_utils:log("Attempting to reconnect..."),
            connect(Data, Timeout),
            continue(disconnected, Data)
    end.

handle_info(Info, State, Data) ->
    case Info of
        {http, {_Ref, stream_start, _X}} ->
            continue(State, Data);
        {http, {_Ref, stream, _X}} ->
            flood_utils:log("Received chunk of data!"),
            continue(State, Data);
        {http, {_Ref, stream_end, _X}} ->
            flood_utils:log("End of stream, disconnecting..."),
            disconnect(Data),
            continue(State, Data);
        {http, {_Ref, {error, Why}}} ->
            flood_utils:log("Connection closed: ~w", [Why]),
            disconnect(Data),
            continue(State, Data)
    end.

handle_sync_event(Event, _, State, Data) ->
    %% TODO Move these to Module:StateName/3
    case Event of
        status       -> reply(State, State, Data);
        disconnect   -> disconnect(Data),
                        reply(State, State, Data);
        terminate    -> terminate(Data),
                        reply(killed, State, Data)
    end.

%% Internal functions

connect(Data) ->
    gen_fsm:send_event(self(), {connect, Data}).

connect(Data, After) ->
    gen_fsm:send_event_after(After, {connect, Data}).

disconnect(Data) ->
    gen_fsm:send_event(self(), {disconnect, Data}).

terminate(Data) ->
    gen_fsm:send_event(self(), {terminate, Data}).

shutdown(Data) ->
    {stop, normal, Data}.

continue(State, Data) ->
    {next_state, State, Data}.

reply(Reply, State, Data) ->
    {reply, Reply, State, Data}.

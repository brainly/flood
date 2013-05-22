-module(flood_fsm).
-behaviour(gen_fsm).

-export([start_link/2, init/1, terminate/3]).
-export([connected/2, connected/3, disconnected/2, disconnected/3]).
-export([handle_info/3, handle_event/3, handle_sync_event/4, code_change/4]).
-export([send_event/2]).

-record(fsm_data, {timeout, url, request_id, protocol}).

%% Gen Server related
start_link({Protocol, Url}, Timeout) ->
    gen_fsm:start_link(?MODULE, #fsm_data{timeout=Timeout, url=Url, protocol = Protocol}, []);

start_link(Url, Timeout) ->
    start_link({http, Url}, Timeout).

init(Data) ->
    connect(Data),
    {ok, disconnected, Data}.

terminate(Reason, State, Data = #fsm_data{request_id = undefined}) ->
    lager:info("FSM terminated:~n- State: ~p~n- Data: ~p~n- Reason: ~p", [State, Data, Reason]),
    ok;

terminate(Reason, State, Data = #fsm_data{request_id = RequestId, protocol = Protocol}) ->
    lager:info("Cancelling an ongoing request ~p...", [RequestId]),
    cancel_request(Protocol, RequestId),
    lager:info("FSM terminated:~n- State: ~p~n- Data: ~p~n- Reason: ~p", [State, Data, Reason]),
    ok.

%% FSM event handlers
connected(Event, _From, Data) ->
    %% TODO Use this instead of handle_sync_event
    connected(Event, Data).

connected(Event, Data) ->
    case Event of
        {disconnect, NewData} ->
            lager:info("Disconnecting..."), % Transition to disconnected state and make sure
            disconnect(NewData),            % it handles attempts to reconnect.
            lager:info("Disconnected!"),
            continue(disconnected, NewData);
        {terminate, LastData} ->
            lager:info("Terminating..."),
            shutdown(LastData);
        _ ->
            continue(connected, Data)
    end.

disconnected(Event, _From, Data) ->
    %% TODO Use this instead of handle_sync_event
    disconnected(Event, Data).

disconnected(Event, Data = #fsm_data{timeout = Timeout}) ->
    case Event of
        {connect, NewData = #fsm_data{url = NewUrl, request_id = RequestId, protocol = Protocol}} ->
            lager:info("Connecting..."),
            %% Cancel an ongoing request (if any) before starting a new one.
            cancel_request(Protocol, RequestId),
            case request(Protocol, NewUrl) of
                undefined    -> lager:info("Unable to connect!"),
                                lager:info("Attempting to reconnect..."),
                                connect(Data, Timeout),
                                continue(disconnected, Data);
                NewRequestId -> lager:info("Connected!"),
                                continue(connected, NewData#fsm_data{request_id = NewRequestId})
            end;
        {terminate, LastData} ->
            lager:info("Terminating..."),
            shutdown(LastData);
        _ ->
            lager:info("Attempting to reconnect..."),
            connect(Data, Timeout),
            continue(disconnected, Data)
    end.

handle_info(Info, State, Data) ->
    case Info of
        {http, {_Ref, stream_start, _}} ->
            continue(State, Data);
        {http, {_Ref, stream, _}} ->
            lager:info("Received a chunk of data!"),
            continue(State, Data);
        {http, {_Ref, stream_end, _}} ->
            lager:info("End of stream, disconnecting..."),
            disconnect(Data),
            continue(State, Data);
        {http, {_Ref, {error, Why}}} ->
            lager:info("Connection closed: ~w", [Why]),
            disconnect(Data),
            continue(State, Data);
        {ws, _Pid, {started, _}} ->
            continue(State, Data);
        {ws, _Pid, {text, _Msg}} ->
            lager:info("Received a chunk of data!"),
            continue(State, Data);
        {ws, _Pid, {closed, Why}} ->
            lager:info("Connection closed: ~w", [Why]),
            disconnect(Data),
            continue(State, Data)
    end.

handle_event(Event, _State, _Data) ->
    lager:warning("Unhandled event received: ~w", [Event]),
    undefined.

handle_sync_event(Event, _From, State, Data) ->
    %% TODO Move these to Module:StateName/3
    case Event of
        status     -> reply(State, State, Data);
        disconnect -> disconnect(Data),
                      reply(State, State, Data);
        terminate  -> terminate(Data),
                      reply(killed, State, Data)
    end.

code_change(_OldVsn, State, _Data, _Extra) ->
    lager:warning("Unhandled code change."),
    {ok, State}.

%% External functions
send_event(Pid, Event) ->
    gen_fsm:sync_send_all_state_event(Pid, Event).

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

%% Communication protocols
request(http, Url) ->
    {ok, RequestId} = httpc:request(get, {Url, []}, [], [{sync, false},
                                                         {stream, self},
                                                         {body_format, binary}]),
    RequestId;

request(ws, Url) ->
    case flood_ws_client:start_link(self(), Url) of
        {ok, Pid} -> Pid;
        {error, _} -> undefined
    end.

cancel_request(_Protocol, undefined) ->
    ok;

cancel_request(http, RequestId) ->
    httpc:cancel_request(RequestId);

cancel_request(ws, HandlerPid) ->
    HandlerPid ! cancel_request.

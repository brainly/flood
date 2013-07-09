-module(flood_fsm).
-behaviour(gen_fsm).

-export([start_link/4, start_link/3, init/1, terminate/3]).
-export([connected/2, connected/3, disconnected/2, disconnected/3]).
-export([handle_info/3, handle_sync_event/4, code_change/4]).
-export([status/1, connect/1, disconnect/1, kill/1]).

-record(fsm_data, {timeout, interval, url, request_id, protocol, data}).

%% Gen Server callbacks
start_link(Url, Interval, Timeout) ->
    start_link(Url, Interval, Timeout, <<"8:::">>).

start_link(Url, Interval, Timeout, Data) ->
    gen_fsm:start_link(?MODULE, #fsm_data{timeout=Timeout, interval=Interval, url=Url, protocol = http, data = Data}, []).

init(Data) ->
    process_flag(trap_exit, true), % So we can clean up later.
    do_connect(Data),
    {ok, disconnected, Data}.

terminate(Reason, State, Data = #fsm_data{request_id = undefined}) ->
    lager:info("FSM terminated:~n- State: ~p~n- Data: ~p~n- Reason: ~p", [State, Data, Reason]),
    ok;

terminate(Reason, State, Data = #fsm_data{request_id = RequestId, protocol = Protocol}) ->
    lager:info("FSM terminated:~n- State: ~p~n- Data: ~p~n- Reason: ~p", [State, Data, Reason]),
    lager:info("Cancelling an ongoing request ~p...", [RequestId]),
    cancel_request(Protocol, RequestId),
    ok.

%% FSM event handlers
connected(Event, _From, Data) ->
    %% TODO Use this instead of handle_sync_event
    connected(Event, Data).

connected(Event, Data) ->
    case Event of
        {disconnect, NewData} ->
            lager:info("Disconnecting..."), % Transition to disconnected state and make sure
            do_disconnect(NewData),         % it handles attempts to reconnect.
            lager:info("Disconnected!"),
            {next_state, disconnected, NewData};

        {connect, NewData = #fsm_data{url = NewUrl, protocol = Protocol}} ->
            lager:info("Upgrading connection to WebSocket..."),
            case new_request(Protocol, NewUrl) of
                undefined    -> lager:info("Unable to connect!"),
                                lager:info("Attempting to reconnect..."),
                                do_connect(Data),
                                {next_state, disconnected, NewData};
                NewRequestId -> Interval = NewData#fsm_data.interval,
                                Timeout = NewData#fsm_data.timeout,
                                DataToSend = NewData#fsm_data.data,
                                lager:info("Upgraded, setup:\n- URL: ~p,\n- Interval: ~p,\n- Timeout: ~p,\n- Event: ~p",
                                           [NewUrl, Interval, Timeout, DataToSend]),
                                start_timer(ping, Interval),
                                start_timer(timeout, Timeout),
                                {next_state, connected, NewData#fsm_data{request_id = NewRequestId}}
            end;

        {terminate, LastData} ->
            lager:info("Terminating..."),
            {stop, normal, LastData};

        {timeout, _ref, ping} ->
            DataToSend = Data#fsm_data.data,
            Protocol = Data#fsm_data.protocol,
            RequestId = Data#fsm_data.request_id,
            lager:info("Sent some data: ~p", [DataToSend]),
            send_data(Protocol, RequestId, DataToSend),
            start_timer(ping, Data#fsm_data.interval),
            {next_state, connected, Data};

        {timeout, _ref, timeout} ->
            lager:info("Session timed out, terminating..."),
            {stop, normal, Data};

        _ ->
            {next_state, connected, Data}
    end.

disconnected(Event, _From, Data) ->
    %% TODO Use this instead of handle_sync_event
    disconnected(Event, Data).

disconnected(Event, Data) ->
    case Event of
        {connect, NewData = #fsm_data{url = NewUrl, request_id = RequestId, protocol = Protocol}} ->
            lager:info("Connecting..."),
            %% Cancel an ongoing request (if any) before starting a new one.
            cancel_request(Protocol, RequestId),
            case new_request(Protocol, NewUrl) of
                undefined    -> lager:info("Unable to connect!"),
                                lager:info("Attempting to reconnect..."),
                                do_connect(Data),
                                {next_state, disconnected, NewData};
                NewRequestId -> lager:info("Connected!"),
                                {next_state, connected, NewData#fsm_data{request_id = NewRequestId}}
            end;

        {terminate, LastData} ->
            lager:info("Terminating..."),
            {stop, normal, LastData};

        {timeout, _ref, timeout} ->
            lager:info("Session timed out, terminating..."),
            {stop, normal, Data};

        _ ->
            {next_state, disconnected, Data}
    end.

handle_info(Info, State, Data) ->
    case Info of
        {http, {_Ref, stream_start, _}} ->
            {next_state, State, Data};

        {http, {_Ref, stream, Msg}} ->
            lager:info("Received a Socket.IO handshake."),
            [Sid, _Heartbeat, Timeout, _Transports] = binary:split(Msg, <<":">>, [global]),
            T = min(Data#fsm_data.timeout, binary_to_integer(Timeout) * 1000),
            %% TODO Add XHR support.
            Url = Data#fsm_data.url ++ "websocket/" ++ binary_to_list(Sid),
            NewData = Data#fsm_data{protocol = ws, url = Url, timeout = T},
            do_connect(NewData),
            {next_state, State, NewData};

        {http, {_Ref, stream_end, _}} ->
            {next_state, State, Data};

        {http, {_Ref, {error, Why}}} ->
            lager:info("Connection closed: ~p", [Why]),
            do_disconnect(Data),
            {next_state, State, Data};

        {ws, _Pid, {started, _}} ->
            {next_state, State, Data};

        {ws, _Pid, {text, Msg}} ->
            lager:info("Received a chunk of data: ~p", [Msg]),
            {next_state, State, Data};

        {ws, _Pid, {closed, Why}} ->
            lager:info("Connection closed: ~p", [Why]),
            do_disconnect(Data),
            {next_state, State, Data};

        {'EXIT', _Pid, Reason} ->
            lager:info("FSM terminating: ~p", [Reason]),
            do_terminate(Data),
            {stop, Reason, Data}
    end.

handle_sync_event(Event, _From, State, Data) ->
    %% TODO Move these to Module:StateName/3
    case Event of
        status     -> {reply, State, State, Data};
        disconnect -> do_disconnect(Data),
                      {reply, State, State, Data};
        terminate  -> do_terminate(Data),
                      {reply, terminated, State, Data}
    end.

code_change(_OldVsn, State, _Data, _Extra) ->
    lager:warning("Unhandled code change."),
    {ok, State}.

%% External functions
status(Pid) ->
    send_event(Pid, status).

connect(Pid) ->
    send_event(Pid, connect).

disconnect(Pid) ->
    send_event(Pid, disconnect).

kill(Pid) ->
    send_event(Pid, terminate).

%% Internal functions
send_event(Pid, Event) ->
    gen_fsm:sync_send_all_state_event(Pid, Event).

do_connect(Data) ->
    gen_fsm:send_event(self(), {connect, Data}).

do_disconnect(Data) ->
    gen_fsm:send_event(self(), {disconnect, Data}).

do_terminate(Data) ->
    gen_fsm:send_event(self(), {terminate, Data}).

new_request(http, Url) ->
    {ok, RequestId} = httpc:request(get,
                                    {"http://" ++ Url, [{"origin", "null"}]},
                                    [],
                                    [{sync, false},
                                     {stream, self},
                                     {body_format, binary}]),
    RequestId;

new_request(ws, Url) ->
    case flood_ws_client:start_link(self(), "ws://" ++ Url) of
        {ok, Pid} -> Pid;
        {error, _} -> undefined
    end.

cancel_request(_Protocol, undefined) ->
    ok;

cancel_request(http, RequestId) ->
    httpc:cancel_request(RequestId);

cancel_request(ws, HandlerPid) ->
    HandlerPid ! cancel_request.

send_data(ws, HandlerPid, Data) ->
    HandlerPid ! {text, Data}.

start_timer(Name, Time) ->
    gen_fsm:start_timer(Time, Name).

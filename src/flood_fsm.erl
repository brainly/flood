-module(flood_fsm).
-behaviour(gen_fsm).

-export([start_link/3, init/1, terminate/3]).
-export([connected/2, connected/3, disconnected/2, disconnected/3]).
-export([handle_info/3, handle_sync_event/4, code_change/4]).
-export([status/1, connect/1, disconnect/1, kill/1]).

-record(fsm_data, {url, transport, data, request_id}).

-include("socketio.hrl").

%% Gen Server callbacks
start_link({Host, Port, Endpoint}, Session, Metadata) ->
    gen_fsm:start_link(?MODULE, {binary_to_list(Host) ++ ":" ++ integer_to_list(Port) ++ binary_to_list(Endpoint),
                                 Session,
                                 Metadata},
                       []).

init({Url, Session, Metadata}) ->
    case flood_session:init([{<<"server.url">>, Url} | Metadata], Session) of
        {noreply, UserData} ->
            Data = #fsm_data{url = Url,
                             data = UserData,
                             transport = undefined},
            flood:inc(all_users),
            flood:inc(alive_users),
            flood:inc(disconnected_users),
            process_flag(trap_exit, true), % So we can clean up later.
            do_connect(Data),
            {ok, disconnected, Data};

        {stop, Reason, _UserData} ->
            {stop, Reason};

        {reply, _Replies, _UserData} ->
            {stop, unable_to_initialize}
    end.

terminate(Reason, State, Data) ->
    lager:info("FSM terminated:~n- State: ~p~n- Data: ~p~n- Reason: ~p", [State, Data, Reason]),
    flood:inc(terminated_users),
    flood:dec(alive_users),
    case State of
        disconnected -> flood:dec(disconnected_users);
        connected    -> flood:dec(connected_users)
    end,
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
            flood:dec(connected_users),
            flood:inc(disconnected_users),
            {next_state, disconnected, NewData};

        {connect, NewData = #fsm_data{url = NewUrl, transport = Transport}} ->
            case new_request(Transport, NewUrl) of
                undefined    -> do_connect(Data),
                                flood:dec(connected_users),
                                flood:inc(disconnected_users),
                                {next_state, disconnected, NewData};
                NewRequestId -> {next_state, connected, NewData#fsm_data{request_id = NewRequestId}}
            end;

        {reconnect, NewData = #fsm_data{url = NewUrl, transport = Transport}} ->
            case Transport of
                <<"xhr-polling">> ->
                    case new_request(Transport, NewUrl) of
                        undefined    -> do_connect(Data),
                                        flood:dec(connected_users),
                                        flood:inc(disconected_users),
                                        {next_state, disconnected, NewData};
                        NewRequestId -> {next_state, connected, NewData#fsm_data{request_id = NewRequestId}}
                    end;

                _ ->
                    %% NOTE WebSocked doesn't need no reconnections.
                    {next_state, connected, NewData}
            end;

        {terminate, LastData} ->
            lager:info("Terminating..."),
            {stop, normal, LastData};

        {timeout, _Ref, Name} ->
            handle_timeout(connected, Name, Data);

        _ ->
            {next_state, connected, Data}
    end.

disconnected(Event, _From, Data) ->
    %% TODO Use this instead of handle_sync_event
    disconnected(Event, Data).

disconnected(Event, Data) ->
    case Event of
        {connect, NewData = #fsm_data{url = NewUrl, transport = Transport}} ->
            lager:info("Connecting..."),
            %% Cancel an ongoing request (if any) before starting a new one.
            case new_request(Transport, NewUrl) of
                undefined    -> lager:info("Unable to connect!"),
                                lager:info("Attempting to reconnect..."),
                                do_connect(Data),
                                {next_state, disconnected, NewData};

                NewRequestId -> lager:info("Connected!"),
                                flood:dec(disconnected_users),
                                flood:inc(connected_users),
                                {next_state, connected, NewData#fsm_data{request_id = NewRequestId}}
            end;

        {terminate, LastData} ->
            lager:info("Terminating..."),
            {stop, normal, LastData};

        _ ->
            {next_state, disconnected, Data}
    end.

handle_info(Info, State, Data) ->
    case Info of
        {ibrowse_async_headers, _RequestId, _Code, _Headers} ->
            {next_state, State, Data};

        {ibrowse_async_response, _RequestId, {error, Why}} ->
            lager:info("Connection closed: ~p", [Why]),
            do_disconnect(Data),
            {next_state, State, Data};

        {ibrowse_async_response_timeout, _RequestId} ->
            lager:info("Connection closed: ~p", [async_response_timeout]),
            do_disconnect(Data),
            {next_state, State, Data};

        {ibrowse_async_response, _RequestId, Msg} ->
            flood:inc(http_incomming),

            %% FIXME This is fuuugly. Defuglyfy
            case Data#fsm_data.transport of
                undefined ->
                    lager:info("Received a Socket.IO handshake."),
                    [Sid, Heartbeat, Timeout, TransportsBin] = binary:split(Msg, <<":">>, [global]),
                    Transports = binary:split(TransportsBin, <<",">>, [global]),
                    Metadata = [{<<"server.sid">>, Sid},
                                {<<"server.heartbeat_timeout">>, binary_to_integer(Heartbeat) * 1000},
                                {<<"server.reconnect_timeout">>, binary_to_integer(Timeout) * 1000},
                                {<<"server.available_trasports">>, Transports}],
                    %% NOTE Assumes they are actually available.
                    UserData = Data#fsm_data.data,
                    Transport = flood_session:get_metadata(<<"session.transport">>, UserData),
                    true = lists:member(Transport, Transports),
                    Url = Data#fsm_data.url ++ binary_to_list(Transport) ++ "/" ++ binary_to_list(Sid),
                    NewUserData = flood_session:add_metadata([{<<"server.url">>, Url} | Metadata], Data#fsm_data.data),
                    NewData = Data#fsm_data{transport = Transport, url = Url, data = NewUserData},
                    do_connect(NewData),
                    {next_state, connected, NewData};

                <<"websocket">> ->
                    lager:error("Received a HTTP reply while in WebSocket mode!"),
                    {next_state, State, Data};

                <<"xhr-polling">> ->
                    %% NOTE Assumes that POST requests receive empty replies.
                    case Msg of
                        <<>> -> {next_state, State, Data};
                        _    -> handle_socketio(connected, Msg, Data)
                    end
            end;

        {ibrowse_async_response_end, _RequestId} ->
            {next_state, State, Data};

        {ws, _Pid, {started, _State}} ->
            {next_state, State, Data};

        {ws, _Pid, {text, Msg}} ->
            flood:inc(ws_incomming),
            handle_socketio(connected, Msg, Data);

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

do_reconnect(Data) ->
    gen_fsm:send_event(self(), {reconnect, Data}).

do_terminate(Data) ->
    gen_fsm:send_event(self(), {terminate, Data}).

new_request(undefined, Url) ->
    new_request(<<"xhr-polling">>, Url);

new_request(<<"xhr-polling">>, Url) ->
    flood:inc(http_outgoing),
    {_, RequestId} = ibrowse:send_req("http://" ++ Url,
                                      [{"connection","keep-alive"},
                                       {"content-type", "text/plain;charset=UTF-8"},
                                       {"content-length", "0"},
                                       {"origin", "null"},
                                       {"accept","*/*"},
                                       {"accept-encoding","gzip,deflate,sdch"},
                                       {"accept-language","pl-PL,pl;q=0.8,en-US;q=0.6,en;q=0.4"}],
                                      get,
                                      [],
                                      [{stream_to, self()},
                                       {response_format, binary}]),
    RequestId;

new_request(<<"websocket">>, Url) ->
    case flood_ws_client:start_link(self(), "ws://" ++ Url) of
        {ok, Pid}       -> Pid;
        {error, _Error} -> undefined
    end.

send_data(Msgs, Data) ->
    send_data(Data#fsm_data.transport, Msgs, Data).

send_data(<<"websocket">>, Msgs, Data) ->
    HandlerPid = Data#fsm_data.request_id,
    lists:map(fun(Msg) ->
                      flood:inc(ws_outgoing),
                      HandlerPid ! {text, socketio_parser:encode(Msg)}
              end,
              Msgs);

send_data(<<"xhr-polling">>, Msgs, Data) ->
    flood:inc(http_outgoing),
    N = erlang:now(),
    T = element(3, N) + element(2, N) * element(1, N) * 1000,
    Url = "http://" ++ Data#fsm_data.url ++ "?t=" ++ integer_to_list(T),
    Encoded = socketio_parser:encode_batch(Msgs),
    ibrowse:send_req(Url,
                     [{"connection","keep-alive"},
                      {"content-type", "text/plain;charset=UTF-8"},
                      {"content-length", integer_to_list(byte_size(Encoded))},
                      {"origin","null"},
                      {"content-type","text/plain;charset=UTF-8"},
                      {"accept","*/*"},
                      {"accept-encoding","gzip,deflate,sdch"},
                      {"accept-language","pl-PL,pl;q=0.8,en-US;q=0.6,en;q=0.4"}],
                     post,
                     Encoded,
                     [{stream_to, self()},
                      {response_format, binary}]).

handle_socketio(State, Msg, Data) ->
    Msgs = socketio_parser:decode_maybe_batch(Msg),
    UserData = Data#fsm_data.data,
    case flood_session:handle_socketio(Msgs, UserData) of
        {reply, Replies, NewUserData} -> NewData = Data#fsm_data{data = NewUserData},
                                         send_data(Replies, NewData),
                                         do_reconnect(NewData),
                                         {next_state, State, NewData};
        {noreply, NewUserData}        -> NewData = Data#fsm_data{data = NewUserData},
                                         do_reconnect(NewData),
                                         {next_state, State, NewData};
        {stop, Reason, NewUserData}   -> {stop, Reason, Data#fsm_data{data = NewUserData}}
    end.

handle_timeout(State, Name, Data) ->
    UserState = Data#fsm_data.data,
    case flood_session:handle_timeout(Name, UserState) of
        {noreply, NewUserData}        -> {next_state, State, Data#fsm_data{data = NewUserData}};
        {reply, Replies, NewUserData} -> NewData = Data#fsm_data{data = NewUserData},
                                         send_data(Replies, NewData),
                                         {next_state, State, NewData};
        {stop, Reason, NewUserData}   -> {stop, Reason, Data#fsm_data{data = NewUserData}}
    end.

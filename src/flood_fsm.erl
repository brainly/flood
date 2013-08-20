-module(flood_fsm).
-behaviour(gen_fsm).

-export([start_link/2, init/1, terminate/3]).
-export([connected/2, connected/3, disconnected/2, disconnected/3]).
-export([handle_info/3, handle_sync_event/4, code_change/4]).
-export([status/1, connect/1, disconnect/1, kill/1]).

-record(fsm_data, {url, transport, data, request_id}).

-include("socketio.hrl").

%% Gen Server callbacks
start_link({Host, Port, Endpoint}, Session) ->
    gen_fsm:start_link(?MODULE, {Host ++ ":" ++ integer_to_list(Port) ++ Endpoint, Session}, []).

init({Url, Session}) ->
    Metadata = [{<<"url">>, Url}],
    case flood_session:init(Metadata, Session) of
        {noreply, UserData} ->
            Data = #fsm_data{url = Url,
                             data = UserData,
                             transport = undefined},
            flood:inc(all),
            flood:inc(alive),
            flood:inc(disconnected),
            process_flag(trap_exit, true), % So we can clean up later.
            do_connect(Data),
            {ok, disconnected, Data};

        {stop, Reason, _UserData} ->
            {stop, Reason};

        {reply, _Replies, _UserData} ->
            {stop, unable_to_initialize}
    end.

terminate(Reason, State, Data = #fsm_data{request_id = undefined}) ->
    lager:info("FSM terminated:~n- State: ~p~n- Data: ~p~n- Reason: ~p", [State, Data, Reason]),
    flood:inc(terminated),
    flood:dec(alive),
    flood:dec(State),
    ok;

terminate(Reason, State, Data = #fsm_data{request_id = RequestId, transport = Transport}) ->
    lager:info("FSM terminated:~n- State: ~p~n- Data: ~p~n- Reason: ~p", [State, Data, Reason]),
    lager:info("Cancelling an ongoing request ~p...", [RequestId]),
    cancel_request(Transport, RequestId),
    flood:inc(terminated),
    flood:dec(alive),
    flood:dec(State),
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
            flood:dec(connected),
            flood:inc(disconnected),
            {next_state, disconnected, NewData};

        {connect, NewData = #fsm_data{url = NewUrl, transport = Transport}} ->
            %% NOTE Used by WebSocket to upgrade the protocol and by XHR to initialize the connection.
            case new_request(Transport, NewUrl) of
                undefined    -> do_connect(Data),
                                flood:dec(connected),
                                flood:inc(disconnected),
                                {next_state, disconnected, NewData};
                NewRequestId -> {next_state, connected, NewData#fsm_data{request_id = NewRequestId}}
            end;

        {reconnect, NewData = #fsm_data{url = NewUrl, transport = Transport}} ->
            %% NOTE Used by XHR polling to renew the GET connection.
            case Transport of
                <<"xhr_polling">> ->
                    case new_request(Transport, NewUrl) of
                        undefined    -> do_connect(Data),
                                        flood:dec(connected),
                                        flood:inc(disconected),
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
        {connect, NewData = #fsm_data{url = NewUrl, request_id = RequestId, transport = Transport}} ->
            lager:info("Connecting..."),
            %% Cancel an ongoing request (if any) before starting a new one.
            cancel_request(Transport, RequestId),
            case new_request(Transport, NewUrl) of
                undefined    -> lager:info("Unable to connect!"),
                                lager:info("Attempting to reconnect..."),
                                do_connect(Data),
                                {next_state, disconnected, NewData};

                NewRequestId -> lager:info("Connected!"),
                                flood:dec(disconnected),
                                flood:inc(connected),
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
                    [Sid, Heartbeat, Timeout, Transports] = binary:split(Msg, <<":">>, [global]),
                    Metadata = [{<<"sid">>, Sid},
                                {<<"heartbeat_timeout">>, Heartbeat},
                                {<<"reconnect_timeout">>, Timeout},
                                {<<"available_trasports">>, Transports}],
                    %% NOTE Assumes they are actually available.
                    UserData = Data#fsm_data.data,
                    Transport = flood_session:get_metadata(<<"transport">>, UserData),
                    case Transport of
                        <<"websocket">> ->
                            Url = Data#fsm_data.url ++ "websocket/" ++ binary_to_list(Sid),
                            NewUserData = flood_session:add_metadata([{<<"url">>, Url} | Metadata], Data#fsm_data.data),
                            NewData = Data#fsm_data{transport = Transport, url = Url, data = NewUserData},
                            do_connect(NewData),
                            {next_state, connected, NewData};

                        <<"xhr_polling">> ->
                            Url = Data#fsm_data.url ++ "xhr-polling/" ++ binary_to_list(Sid),
                            NewUserData = flood_session:add_metadata([{<<"url">>, Url} | Metadata], Data#fsm_data.data),
                            NewData = Data#fsm_data{transport = Transport, url = Url, data = NewUserData},
                            do_connect(NewData),
                            {next_state, State, NewData}
                    end;

                <<"websocket">> ->
                    lager:error("Received a HTTP reply while in WebSocket mode!"),
                    {next_state, State, Data};

                <<"xhr_polling">> ->
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
    new_request(<<"xhr_polling">>, Url);

new_request(<<"xhr_polling">>, Url) ->
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

cancel_request(_Protocol, undefined) ->
    ok;

cancel_request(undefined, _RequestId) ->
    ok; %% FIXME

cancel_request(<<"xhr_polling">>, RequestId) ->
    ok; %% FIXME

cancel_request(<<"websocket">>, HandlerPid) ->
    HandlerPid ! cancel_request.

send_data(Msgs, Data) ->
    send_data(Data#fsm_data.transport, Msgs, Data).

send_data(<<"websocket">>, Msgs, Data) ->
    HandlerPid = Data#fsm_data.request_id,
    lists:map(fun(Msg) ->
                      flood:inc(ws_outgoing),
                      HandlerPid ! {text, socketio_parser:encode(Msg)}
              end,
              Msgs);

send_data(<<"xhr_polling">>, Msgs, Data) ->
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

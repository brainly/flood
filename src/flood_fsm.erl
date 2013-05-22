-module(flood_fsm).
-behaviour(gen_fsm).

-export([start_link/2, init/1, terminate/3]).
-export([connected/2, connected/3, disconnected/2, disconnected/3]).
-export([handle_info/3, handle_event/3, handle_sync_event/4, code_change/4]).
-export([send_event/2]).

-record(fsm_data, {timeout, url, request_id}).

%% Gen Server callbacks
start_link(Url, Timeout) ->
    gen_fsm:start_link(?MODULE, #fsm_data{timeout=Timeout, url=Url}, []).

init(Data) ->
    connect(Data),
    {ok, disconnected, Data}.

terminate(Reason, State, Data = #fsm_data{request_id = undefined}) ->
    lager:info("FSM terminated:~n- State: ~p~n- Data: ~p~n- Reason: ~p", [State, Data, Reason]),
    ok;

terminate(Reason, State, Data = #fsm_data{request_id = RequestId}) ->
    lager:info("Cancelling an ongoing request ~p...", [RequestId]),
    httpc:cancel_request(RequestId),
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
        {connect, NewData = #fsm_data{url = NewUrl, request_id = RequestId}} ->
            lager:info("Connecting..."),
            %% Cancel an ongoing request (if any) before starting a new one.
            httpc:cancel_request(RequestId),
            {ok, NewRequestId} = httpc:request(get, {NewUrl, []}, [], [{sync, false},
                                                                       {stream, self},
                                                                       {body_format, binary}]),
            lager:info("Connected!"),
            continue(connected, NewData#fsm_data{request_id = NewRequestId});
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
        {http, {_Ref, stream_start, _X}} ->
            continue(State, Data);
        {http, {_Ref, stream, _X}} ->
            lager:info("Received chunk of data!"),
            continue(State, Data);
        {http, {_Ref, stream_end, _X}} ->
            lager:info("End of stream, disconnecting..."),
            disconnect(Data),
            continue(State, Data);
        {http, {_Ref, {error, Why}}} ->
            lager:info("Connection closed: ~p", [Why]),
            disconnect(Data),
            continue(State, Data)
    end.

handle_event(Event, _State, _Data) ->
    lager:warning("Unhandled event received: ~p", [Event]),
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

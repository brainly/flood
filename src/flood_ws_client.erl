-module(flood_ws_client).
-behaviour(websocket_client_handler).

-export([start_link/2, init/2]).
-export([websocket_handle/3, websocket_info/3, websocket_terminate/3]).

start_link(OwnerPid, Url) ->
    websocket_client:start_link(Url, ?MODULE, OwnerPid).

init(OwnerPid, _ConnState) ->
    {ok, OwnerPid}.

%% WebSocket handlers
websocket_handle({pong, _Msg}, _ConnState, State) ->
    {ok, State};

websocket_handle({ping, _Msg}, _ConnState, State) ->
    {ok, State};

websocket_handle(Frame = {text, _Msg}, ConnState, State) ->
    send(ConnState, State, Frame),
    {ok, State}.

websocket_info(start, ConnState, State) ->
    send(ConnState, State, {started, ConnState}),
    {ok, State};

websocket_info(cancel_request, _ConnState, State) ->
    {close, <<"Connection closed by client.">>, State};

websocket_info(Frame = {text, _Msg}, _ConnState, State) ->
    {reply, Frame, State}.

websocket_terminate(Reason, ConnState, State) ->
    send(ConnState, State, {closed, Reason}),
    ok.

%% Internal functions
send(ConnState, State, Message) ->
    Owner = State,
    Protocol = websocket_req:protocol(ConnState),
    Msg = {Protocol, self(), Message},
    Owner ! Msg.

-module(flood_session).

%%-export([init/2, run/2, dispatch/3, handle/3, add_metadata/2, get_metadata/2]).
-compile(export_all).

-record(user_state, {metadata,
                     counters,
                     timers,
                     timeout_handlers,
                     event_handlers,
                     socketio_handlers}).

%% External functions:
init(InitData, Session) ->
    Name = proplists:get_value(<<"session_name">>, Session),
    Transport = proplists:get_value(<<"transport">>, Session),
    Weight = proplists:get_value(<<"weight">>, Session),
    Metadata = proplists:get_value(<<"metadata">>, Session),
    Actions = proplists:get_value(<<"do">>, Session),
    State = #user_state{metadata = InitData ++ [{<<"session_name">>, Name},
                                                {<<"transport">>, Transport},
                                                {<<"weight">>, Weight}
                                                | Metadata],
                        counters = dict:new(),
                        timers = dict:new(),
                        timeout_handlers = dict:new(),
                        event_handlers = dict:new(),
                        socketio_handlers = dict:new()},
    run(Actions, State).

run([], State) ->
    State;

run([Action | Actions], State) ->
    Name = proplists:get_value(<<"op">>, Action),
    run(Actions, dispatch(Name, Action, State)).

dispatch(<<"start_timer">>, Action, State) ->
    Time = proplists:get_value(<<"time">>, Action),
    Name = proplists:get_value(<<"name">>, Action),
    Timer = gen_fsm:start_timer(Time, Name),
    Timers = dict:insert(Name, Timer, State#user_state.timers),
    State#user_state{timers = Timers};

dispatch(<<"stop_timer">>, Action, State) ->
    Name = proplists:get_value(<<"name">>, Action),
    Timer = dict:fetch(Name, State#user_state.timers),
    get_fsm:cancel_timer(Timer),
    Timers = dict:erase(Name, State#user_state.timers),
    State#user_state{timers = Timers};

dispatch(<<"restart_timer">>, Action, State) ->
    dispatch(<<"start_timer">>, Action, dispatch(<<"stop_timer">>, Action, State));

dispatch(<<"on_timeout">>, Action, State) ->
    Name = proplists:get_value(<<"name">>, Action),
    Actions = proplists:get_value(<<"do">>, Action),
    TH = dict:append_list(Name, Actions, State#user_state.timeout_handlers),
    State#user_state{timeout_handlers = TH};

dispatch(<<"inc_counter">>, Action, State) ->
    State;

dispatch(<<"dec_counter">>, Action, State) ->
    State;

dispatch(<<"set_counter">>, Action, State) ->
    State;

dispatch(<<"on_event">>, Action, State) ->
    Name = proplists:get_value(<<"name">>, Action),
    Actions = proplists:get_value(<<"do">>, Action),
    TH = dict:append_list(Name, Actions, State#user_state.event_handlers),
    State#user_state{event_handlers = TH};

dispatch(<<"on_socketio">>, Action, State) ->
    Name = proplists:get_value(<<"opcode">>, Action),
    Actions = proplists:get_value(<<"do">>, Action),
    TH = dict:append_list(Name, Actions, State#user_state.socketio_handlers),
    State#user_state{socketio_handlers = TH};

dispatch(<<"emit_event">>, Action, State) ->
    State;

dispatch(<<"emit_socketio">>, Action, State) ->
    State;

dispatch(<<"terminate">>, Action, State) ->
    State;

dispatch(<<"log">>, Action, State) ->
    What = proplists:get_value(<<"what">>, Action),
    lager:info("~p", [lists:map(fun(W) -> lookup(W, State#user_state.metadata) end, What)]),
    State;

dispatch(_Name, _Action, State) ->
    State.

handle(Name, Handlers, State) ->
    case dict:find(Name, Handlers) of
        {ok, Actions} -> run(Actions, State);
        _             -> State
    end.

get_metadata(Name, State) ->
    proplists:get_value(Name, State#user_state.metadata).

add_metadata(Metadata, State) ->
    State#user_state{metadata = Metadata ++ State#user_state.metadata}.

%% Internal functions:
sample_session() ->
    [{<<"session_name">>,<<"Sample Session">>},
     {<<"transport">>,<<"xhr_polling">>},
     {<<"weight">>,0.2},
     {<<"metadata">>,
      [{<<"foo">>,<<"bar">>},{<<"baz">>,<<"hurr">>}]},
     {<<"do">>,
      [[{<<"op">>,<<"on_socketio">>},
        {<<"opcode">>, <<"1">>},
        {<<"do">>, [[{<<"op">>,<<"log">>},
                     {<<"what">>,[<<"Client connected: ">>, <<"$session_name">>, <<"$sid">>]}]]}]]}].

lookup(<<"$", What/binary>>, Metadata) ->
    proplists:get_value(What, Metadata);

lookup(What, _Metadata) ->
    What.

timeout_handlers(State) ->
    State#user_state.timeout_handlers.

event_handlers(State) ->
    State#user_state.event_handlers.

socketio_handlers(State) ->
    State#user_state.socketio_handlers.

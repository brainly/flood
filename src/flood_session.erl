-module(flood_session).

-export([init/2, run/2, dispatch/3, handle_socketio/2, handle_event/4, handle_timeout/2, add_metadata/2, get_metadata/2]).

-record(user_state, {metadata,
                     counters,
                     timers,
                     timeout_handlers,
                     event_handlers,
                     socketio_handlers}).

-include("socketio.hrl").

-import(flood_session_utils, [json_match/2, json_subst/2, combine/2, sio_type/1, sio_opcode/1]).

%% External functions:
init(InitData, Session) ->
    Name = get_value(<<"name">>, Session),
    Transport = get_value(<<"transport">>, Session),
    Weight = get_value(<<"weight">>, Session),
    Metadata = get_value(<<"metadata">>, Session),
    State = #user_state{metadata = InitData ++ [{<<"session.name">>, Name},
                                                {<<"session.transport">>, Transport},
                                                {<<"session.weight">>, Weight}
                                                | Metadata],
                        counters = dict:new(),
                        timers = dict:new(),
                        timeout_handlers = dict:new(),
                        event_handlers = dict:new(),
                        socketio_handlers = dict:new()},
    Actions = get_value(<<"do">>, Session),
    run(Actions, State).

run(Actions, State) ->
    run_iter(Actions, {noreply, State}).

run_iter([], Acc) ->
    Acc;

run_iter(_Actions, {stop, Reason, State}) ->
    {stop, Reason, State};

run_iter([[Name, Action] | Actions], {noreply, State}) ->
    run_iter(Actions, dispatch(Name, Action, State));

run_iter([[Name, Action] | Actions], {reply, Replies, State}) ->
    run_iter(Actions, combine(dispatch(Name, Action, State), {reply, Replies, State})).

dispatch(<<"start_timer">>, Action, State) ->
    Time = get_value(<<"time">>, Action, State),
    Name = get_value(<<"name">>, Action, State),
    Timer = gen_fsm:start_timer(Time, Name),
    Timers = dict:store(Name, {Timer, Time}, State#user_state.timers),
    {noreply, State#user_state{timers = Timers}};

dispatch(<<"stop_timer">>, Action, State) ->
    Name = get_value(<<"name">>, Action, State),
    {Timer, Time} = dict:fetch(Name, State#user_state.timers),
    case gen_fsm:cancel_timer(Timer) of
        false     -> flood:update(Name, Time);
        Remaining -> flood:update(Name, Time - Remaining)
    end,
    Timers = dict:erase(Name, State#user_state.timers),
    {noreply, State#user_state{timers = Timers}};

dispatch(<<"restart_timer">>, Action, State) ->
    case dispatch(<<"stop_timer">>, Action, State) of
        {noreply, NewState}      -> dispatch(<<"start_timer">>, Action, NewState);
        {stop, Reason, NewState} -> {stop, Reason, NewState}
    end;

dispatch(<<"on_timeout">>, Action, State) ->
    Name = get_value(<<"name">>, Action, State),
    Actions = get_value(<<"do">>, Action),
    TH = dict:append_list(Name, Actions, State#user_state.timeout_handlers),
    {noreply, State#user_state{timeout_handlers = TH}};

dispatch(<<"inc">>, Action, State) ->
    Value = get_value(<<"value">>, Action, 1, State),
    Name = get_value(<<"name">>, Action, State),
    flood:inc(Name, Value),
    {noreply, State};

dispatch(<<"dec">>, Action, State) ->
    Value = get_value(<<"value">>, Action, 1, State),
    Name = get_value(<<"name">>, Action, State),
    flood:dec(Name, Value),
    {noreply, State};

dispatch(<<"set">>, Action, State) ->
    Name = get_value(<<"name">>, Action, State),
    Value = get_value(<<"value">>, Action, State),
    flood:set(Name, Value),
    {noreply, State};

dispatch(<<"match">>, Action, State) ->
    Subject = get_value(<<"subject">>, Action, State),
    Name = get_value(<<"name">>, Action, <<"match">>, State),

    case get_value(<<"re">>, Action, State) of
        undefined ->
            PatternJSON = get_value(<<"json">>, Action, State),
            json_match(Subject, PatternJSON, Name, Action, State);

        Regexp    ->
            regex_match(Subject, Regexp, Name, Action, State)
    end;

dispatch(<<"on_event">>, Action, State) ->
    Name = get_value(<<"name">>, Action, State),
    Actions = get_value(<<"do">>, Action),
    TH = dict:append_list(Name, Actions, State#user_state.event_handlers),
    {noreply, State#user_state{event_handlers = TH}};

dispatch(<<"on_socketio">>, Action, State) ->
    Opcode = get_value(<<"opcode">>, Action, State),
    Actions = get_value(<<"do">>, Action),
    TH = dict:append_list(Opcode, Actions, State#user_state.socketio_handlers),
    {noreply, State#user_state{socketio_handlers = TH}};

dispatch(<<"emit_event">>, Action, State) ->
    Event = jsonx:encode({json_subst(Action, State#user_state.metadata)}),
    {reply, [#sio_message{type = event, data = Event}], State};

dispatch(<<"emit_socketio">>, Action, State) ->
    Opcode = get_value(<<"opcode">>, Action, State),
    %% FIXME Add ACKs.
    Endpoint = get_value(<<"endpoint">>, Action, <<"">>, State),
    Data = get_value(<<"data">>, Action, <<"">>, State),
    {reply, [#sio_message{type = sio_type(Opcode), endpoint = Endpoint, data = Data}], State};

dispatch(<<"terminate">>, Action, State) ->
    Reason = get_value(<<"reason">>, Action, State),
    {stop, {shutdown, Reason}, State};

dispatch(<<"log">>, Action, State) ->
    Format = get_value(<<"format">>, Action, State),
    Values = get_value(<<"values">>, Action, [], State),
    lager:notice(Format, Values),
    {noreply, State};

dispatch(Name, _Action, State) ->
    {stop, {unknown_action, Name}, State}.

get_metadata(Name, State) ->
    proplists:get_value(Name, State#user_state.metadata).

add_metadata(Metadata, State) ->
    State#user_state{metadata = Metadata ++ State#user_state.metadata}.

handle_timeout(Name, State) ->
    {_Timer, Time} = dict:fetch(Name, State#user_state.timers),
    flood:update(Name, Time),
    with_tmp_metadata([{<<"timer">>, Name}],
                      fun(S) ->
                              handle(Name, S#user_state.timeout_handlers, S)
                      end,
                      State).

handle_event(Event, Name, Args, State) ->
    %% FIXME Name and Args should be strings.
    with_tmp_metadata([{<<"event">>, Event},
                       {<<"event.name">>, Name},
                       {<<"event.args">>, Args}],
                      fun(S) ->
                              handle(Name, S#user_state.event_handlers, S)
                      end,
                      State).

handle_socketio(SIOMessages, State) when is_list(SIOMessages) ->
    lists:foldr(fun(_, {stop, Reason, NewState}) ->
                        {stop, Reason, NewState};
                   (Message, Acc = {reply, _, NewState}) ->
                        combine(handle_socketio(Message, NewState), Acc);

                   (Message, Acc = {noreply, NewState}) ->
                        combine(handle_socketio(Message, NewState), Acc)
                end,
                {noreply, State},
                SIOMessages);

handle_socketio(SIOMessage = #sio_message{type = event, endpoint = Endpoint, data = Data}, State) ->
    %% TODO Add acks.
    with_tmp_metadata([{<<"message">>, SIOMessage},
                       {<<"message.opcode">>, sio_opcode(event)},
                       {<<"message.endpoint">>, Endpoint},
                       {<<"message.data">>, Data}],
                      fun(S) ->
                              JSON = jsonx:decode(Data, [{format, proplist}]),
                              Name = proplists:get_value(<<"name">>, JSON),
                              Args = proplists:get_value(<<"args">>, JSON),
                              case handle(sio_opcode(event), S#user_state.socketio_handlers, S) of
                                  {stop, Reason, NewState}    -> {stop, Reason, NewState};
                                  Else = {noreply, NewState}  -> combine(handle_event(Data, Name, Args, NewState), Else);
                                  Else = {reply, _, NewState} -> combine(handle_event(Data, Name, Args, NewState), Else)
                              end
                      end,
                      State);

handle_socketio(#sio_message{type = disconnect}, State) ->
    {stop, {shutdown, disconnected}, State};

handle_socketio(SIOMessage = #sio_message{type = Type, endpoint = Endpoint, data = Data}, State) ->
    %% TODO Add acks.
    with_tmp_metadata([{<<"message">>, SIOMessage},
                       {<<"message.opcode">>, sio_opcode(Type)},
                       {<<"message.endpoint">>, Endpoint},
                       {<<"message.data">>, Data}],
                      fun(S) ->
                              handle(sio_opcode(Type), S#user_state.socketio_handlers, S)
                      end,
                      State).

%% Internal functions:
handle(Name, Handlers, State) ->
    case dict:find(Name, Handlers) of
        {ok, Actions} -> run(Actions, State);
        _             -> {noreply, State}
    end.

get_value(What, Where) ->
    get_value(What, Where, undefined).

get_value(What, Where, State = #user_state{}) ->
    get_value(What, Where, undefined, State);

get_value(What, Where, Default) ->
    proplists:get_value(What, Where, Default).

get_value(What, Where, Default, State = #user_state{}) ->
    json_subst(get_value(What, Where, Default), State#user_state.metadata).

with_tmp_metadata(Metadata, Fun, State) ->
    OldMetadata = State#user_state.metadata,
    case Fun(add_metadata(Metadata, State)) of
        {stop, Reason, NewState}   -> {stop, Reason, NewState#user_state{metadata = OldMetadata}};
        {reply, Replies, NewState} -> {reply, Replies, NewState#user_state{metadata = OldMetadata}};
        {noreply, NewState}        -> {noreply, NewState#user_state{metadata = OldMetadata}}
    end.

regex_match(Subject, Regexp, Name, Action, State) ->
    case re:run(Subject, Regexp, [{capture, all_but_first, binary}]) of
        {match, Matches} ->
            OnMatch = get_value(<<"on_match">>, Action, []),
            with_tmp_metadata(lists:map(fun({Index, Match}) ->
                                                I = integer_to_binary(Index),
                                                N = <<Name/binary, "_", I/binary>>,
                                                {N, Match}
                                        end,
                                        lists:zip(lists:seq(0, length(Matches)-1),
                                                  Matches)),
                              fun(S) ->
                                      run(OnMatch, S)
                              end,
                              State);

        nomatch ->
            OnNomatch = get_value(<<"on_nomatch">>, Action, []),
            with_tmp_metadata([{Name, undefined}],
                              fun(S) ->
                                      run(OnNomatch, S)
                              end,
                              State)
    end.

json_match(Subject, Pattern, Name, Action, State) ->
    case json_match(Subject, Pattern) of
        true ->
            OnMatch = get_value(<<"on_match">>, Action, []),
            with_tmp_metadata([Name, Pattern],
                              fun(S) ->
                                      run(OnMatch, S)
                              end,
                              State);

        false ->
            OnNomatch = get_value(<<"on_nomatch">>, Action, []),
            with_tmp_metadata([{Name, undefined}],
                              fun(S) ->
                                      run(OnNomatch, S)
                              end,
                              State)
    end.


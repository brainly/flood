-module(flood_session).
-author('kajetan.rzepecki@zadane.pl').

-export([init/2, run/2, dispatch/3, handle_socketio/2, handle_event/4, handle_timeout/2, add_metadata/2, get_metadata/2]).

-record(user_state, {metadata,
                     counters,
                     timers,
                     timeout_handlers,
                     event_handlers,
                     socketio_handlers}).

-include("socketio.hrl").
-include("flood_sessions.hrl").

-import(flood_session_utils, [json_match/2, json_subst/2, combine/2, sio_type/1, sio_ack/1, sio_opcode/1]).
-import(flood_session_utils, [get_value/2, get_value/3, get_value/4]).

%% External functions:
init(InitData, Session) ->
    State = #user_state{metadata = InitData ++ Session#flood_session.metadata,
                        counters = dict:new(),
                        timers = dict:new(),
                        timeout_handlers = dict:new(),
                        event_handlers = dict:new(),
                        socketio_handlers = dict:new()},
    run(Session#flood_session.base_actions, State).

run(undefined, State) ->
    {noreply, State};

run(Actions, State) ->
    run_iter(Actions, {noreply, State}).

run_iter([], Acc) ->
    Acc;

run_iter(_Actions, {stop, Reason, State}) ->
    {stop, Reason, State};

run_iter([[Name | Args] | Actions], {noreply, State}) ->
    run_iter(Actions, dispatch(Name, Args, State));

run_iter([[Name | Args] | Actions], {reply, Replies, State}) ->
    run_iter(Actions, combine(dispatch(Name, Args, State), {reply, Replies, State})).

dispatch(<<"start_timer">>, [Name, Time], State) ->
    dispatch(<<"start_timer">>, [[{<<"name">>, Name}, {<<"time">>, Time}]], State);

dispatch(<<"start_timer">>, [Args], State) ->
    Name = get_value(<<"name">>, Args, md(State)),
    Time = get_value(<<"time">>, Args, md(State)),
    Timer = gen_fsm:start_timer(Time, Name),
    Timers = dict:store(Name, {Timer, Time}, State#user_state.timers),
    {noreply, State#user_state{timers = Timers}};

dispatch(<<"stop_timer">>, [Args], State) when is_list(Args) ->
    Name = get_value(<<"name">>, Args, md(State)),
    {Timer, Time} = dict:fetch(Name, State#user_state.timers),
    case gen_fsm:cancel_timer(Timer) of
        false     -> flood:update(Name, Time);
        Remaining -> flood:update(Name, Time - Remaining)
    end,
    Timers = dict:erase(Name, State#user_state.timers),
    {noreply, State#user_state{timers = Timers}};

dispatch(<<"stop_timer">>, [Name], State) ->
    dispatch(<<"stop_timer">>, [[{<<"name">>, Name}]], State);

dispatch(<<"restart_timer">>, [Args], State) when is_list(Args) ->
    Name = get_value(<<"name">>, Args, md(State)),
    Time = get_value(<<"time">>, Args, md(State), 0),
    case dispatch(<<"stop_timer">>, [Name], State) of
        {noreply, NewState}      -> dispatch(<<"start_timer">>, [Name, Time], NewState);
        {stop, Reason, NewState} -> {stop, Reason, NewState}
    end;

dispatch(<<"restart_timer">>, [Name, Time], State) ->
    dispatch(<<"restart_timer">>, [[{<<"name">>, Name}, {<<"time">>, Time}]], State);

dispatch(<<"timed">>, [Args], State) ->
    Name = get_value(<<"name">>, Args, md(State)),
    Actions = get_value(<<"do">>, Args),
    {Time, Reply} = timer:tc(fun() -> run(Actions, State) end),
    flood:update(Name, Time div 1000),
    Reply;

dispatch(<<"on_timeout">>, [[]], State) ->
    {noreply, State};

dispatch(<<"on_timeout">>, [[{N, Actions} | Args]], State) ->
    Name = json_subst(N, md(State)),
    TH = dict:append_list(Name, Actions, State#user_state.timeout_handlers),
    dispatch(<<"on_timeout">>, [Args], State#user_state{timeout_handlers = TH});

dispatch(<<"inc">>, [Args], State) when is_list(Args) ->
    Name = get_value(<<"name">>, Args, md(State)),
    Value = get_value(<<"value">>, Args, md(State), 1),
    flood:inc(Name, Value),
    {noreply, State};

dispatch(<<"inc">>, [Name], State) ->
    dispatch(<<"inc">>, [Name, 1], State);

dispatch(<<"inc">>, [Name, Value], State) ->
    dispatch(<<"inc">>, [[{<<"name">>, Name}, {<<"value">>, Value}]], State);

dispatch(<<"dec">>, [Args], State) when is_list(Args) ->
    Name = get_value(<<"name">>, Args, md(State)),
    Value = get_value(<<"value">>, Args, md(State), 1),
    flood:dec(Name, Value),
    {noreply, State};

dispatch(<<"dec">>, [Name], State) ->
    dispatch(<<"dec">>, [Name, 1], State);

dispatch(<<"dec">>, [Name, Value], State) ->
    dispatch(<<"dec">>, [[{<<"name">>, Name}, {<<"value">>, Value}]], State);

dispatch(<<"set">>, [Args], State) ->
    Name = get_value(<<"name">>, Args, md(State)),
    Value = get_value(<<"value">>, Args, md(State)),
    flood:set(Name, Value),
    {noreply, State};

dispatch(<<"set">>, [Name, Value], State) ->
    dispatch(<<"set">>, [[{<<"name">>, Name}, {<<"value">>, Value}]], State);

dispatch(<<"match">>, [Args], State) ->
    Subject = get_value(<<"subject">>, Args, md(State)),
    Name = get_value(<<"name">>, Args, md(State), <<"match">>),
    case get_value(<<"re">>, Args, md(State)) of
        undefined -> PatternJSON = get_value(<<"json">>, Args),
                     json_match(Subject, PatternJSON, Name, Args, State);
        Regexp    -> regex_match(Subject, Regexp, Name, Args, State)
    end;

dispatch(<<"case">>, [Condition, Branches], State) ->
    dispatch(<<"case">>, [[{<<"condition">>, Condition}, {<<"branches">>, Branches}]], State);

dispatch(<<"case">>, [Args], State) ->
    Condition = get_value(<<"condition">>, Args, md(State)),
    Branches = get_value(<<"branches">>, Args, md(State), []),
    case_dispatch(Condition, Branches, State);

dispatch(<<"on_event">>, [[]], State) ->
    {noreply, State};

dispatch(<<"on_event">>, [[{N, Actions}| Args]], State) ->
    Name = json_subst(N, md(State)),
    TH = dict:append_list(Name, Actions, State#user_state.event_handlers),
    dispatch(<<"on_event">>, [Args], State#user_state{event_handlers = TH});

dispatch(<<"on_socketio">>, [[]], State) ->
    {noreply, State};

dispatch(<<"on_socketio">>, [[{Op, Actions} | Args]], State) ->
    Opcode = json_subst(Op, md(State)),
    TH = dict:append_list(Opcode, Actions, State#user_state.socketio_handlers),
    dispatch(<<"on_socketio">>, [Args], State#user_state{socketio_handlers = TH});

dispatch(<<"emit_event">>, [Event], State) ->
   dispatch(<<"emit_event">>, [Event, [{<<"id">>, <<"">>}]], State);

dispatch(<<"emit_event">>, [Event, Args], State) ->
    E = jsonx:encode({json_subst(Event, State#user_state.metadata)}),
    dispatch(<<"emit_socketio">>, [[{<<"opcode">>, <<"5">>}, {<<"endpoint">>, <<"">>}, {<<"data">>, E} | Args]], State);

dispatch(<<"emit_socketio">>, [Args], State) ->
    Opcode = get_value(<<"opcode">>, Args, md(State)),
    %% FIXME Add ACKs.
    Endpoint = get_value(<<"endpoint">>, Args, md(State), <<"">>),
    Id = get_value(<<"id">>, Args, md(State), <<"">>),
    Data = get_value(<<"data">>, Args, md(State), <<"">>),
    {reply, [#sio_message{type = sio_type(Opcode), id = sio_ack(Id), endpoint = Endpoint, data = Data}], State};

dispatch(<<"emit_http">>, [Args], State) ->
    Method = get_value(<<"method">>, Args, md(State)),
    Url = get_value(<<"url">>, Args, md(State)),
    Body = get_value(<<"body">>, Args, md(State), <<"">>),
    Headers = get_value(<<"headers">>, Args, md(State), [{"origin", "null"}]),
    Timeout = get_value(<<"timeout">>, Args, md(State), infinity),
    OnReply = get_value(<<"on_reply">>, Args),
    OnError = get_value(<<"on_error">>, Args),
    http_request(Method, Url, Headers, Body, Timeout, OnReply, OnError, State);

dispatch(<<"terminate">>, [Args], State) when is_list(Args) ->
    Reason = get_value(<<"reason">>, Args, md(State)),
    {stop, {shutdown, Reason}, State};

dispatch(<<"terminate">>, [Reason], State) ->
    dispatch(<<"terminate">>, [[{<<"reason">>, Reason}]], State);

dispatch(<<"log">>, [Args], State) when is_list(Args) ->
    Format = get_value(<<"format">>, Args, md(State)),
    Values = get_value(<<"values">>, Args, md(State), []),
    lager:notice(Format, Values),
    {noreply, State};

dispatch(<<"log">>, [Format], State) ->
    dispatch(<<"log">>, [Format, []], State);

dispatch(<<"log">>, [Format, Values], State) ->
    dispatch(<<"log">>, [[{<<"format">>, Format}, {<<"values">>, Values}]], State);

dispatch(<<"!log">>, _Args, State) ->
    {noreply, State};

dispatch(<<"def">>, [Args], State) ->
    {noreply, add_metadata(lists:map(fun({Name, Value}) ->
                                             {Name, json_subst(Value, md(State))}
                                     end,
                                     Args),
                           State)};

dispatch(Name, _Args, State) ->
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
                              Name = get_value(<<"name">>, JSON),
                              Args = get_value(<<"args">>, JSON),
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

with_tmp_metadata(Metadata, Fun, State) ->
    OldMetadata = State#user_state.metadata,
    case Fun(add_metadata(Metadata, State)) of
        {stop, Reason, NewState}   -> {stop, Reason, NewState#user_state{metadata = OldMetadata}};
        {reply, Replies, NewState} -> {reply, Replies, NewState#user_state{metadata = OldMetadata}};
        {noreply, NewState}        -> {noreply, NewState#user_state{metadata = OldMetadata}}
    end.

regex_match(Subject, Regexp, Name, Action, State) ->
    do_match(re:run(Subject, Regexp, [{capture, all_but_first, binary}]), Name, Action, State).

json_match(Subject, Pattern, Name, Action, State) ->
    do_match(json_match(Subject, Pattern), Name, Action, State).

do_match(Value, Name, Action, State) ->
    case Value of
        {match, Matches} ->
            OnMatch = get_value(<<"on_match">>, Action),
            with_tmp_metadata(lists:map(fun({_Index, {N, Match}}) ->
                                                {N, Match};

                                           ({Index, Match}) ->
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
            OnNomatch = get_value(<<"on_nomatch">>, Action),
            with_tmp_metadata([{Name, undefined}],
                              fun(S) ->
                                      run(OnNomatch, S)
                              end,
                              State)
    end.

http_request(Method, Url, Headers, Body, Timeout, OnReply, OnError, State) ->
    BodyBin = binarize(Body),
    flood:inc(http_outgoing),
    case ibrowse:send_req(binary_to_list(Url),
                          fix_headers([{"content-type", "text/plain;charset=UTF-8"},
                                       {"content-length", integer_to_list(byte_size(BodyBin))}
                                       | Headers]),
                          http_method(Method),
                          BodyBin,
                          [{response_format, binary}],
                          Timeout)
    of
        {ok, Status, ResponseHeaders, Reply} ->
            with_tmp_metadata([{<<"reply.status">>, Status},
                               {<<"reply.headers">>, ResponseHeaders},
                               {<<"reply.body">>, Reply}],
                              fun(S) ->
                                      run(OnReply, S)
                              end,
                              State);
        _Otherwise ->
            with_tmp_metadata([],
                              fun(S) ->
                                      run(OnError, S)
                              end,
                              State)
    end.

binarize(Thing) when is_binary(Thing) ->
    Thing;

binarize(Thing) ->
    jsonx:encode(Thing).

fix_headers([]) ->
    [];

fix_headers([{K, V} | Rest]) ->
    [{stringify(K), stringify(V)} | fix_headers(Rest)];

fix_headers([_Other | Rest]) ->
    %% NOTE Silently skips some of the malformed headers.
    fix_headers(Rest).

stringify(Thing) when is_list(Thing) ->
    Thing;

stringify(Thing) when is_binary(Thing) ->
    binary_to_list(Thing).

http_method(<<"GET">>) ->
    get;
http_method(<<"POST">>) ->
    post;
http_method(_Other) ->
    unknown.

md(State = #user_state{}) ->
    State#user_state.metadata.

case_dispatch(_Condition, [], State) ->
    {noreply, State};

case_dispatch(Condition, [{Condition, Actions} | _Ignored], State) ->
    run(Actions, State);

case_dispatch(Condition, [{_Value, _Actions} | Rest], State) ->
    case_dispatch(Condition, Rest, State).

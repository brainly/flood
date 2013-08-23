-module(flood_manager).
-behaviour(gen_server).

-export([start_link/0, init/1, terminate/2]).
-export([handle_cast/2, handle_call/3, handle_info/2, code_change/3]).
-export([run/1]).

-record(manager_state, {server, phases, sessions, beta}).

%% Gen Server callbacks:
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE,[], []).

init([]) ->
    random:seed(erlang:now()),
    {ok, #manager_state{beta = 0.0}}.

terminate(Reason, State) ->
    lager:info("Manager terminated:~n- State: ~p~n- Reason: ~p", [State, Reason]),
    ok.

%% External functions:
run(TestConfig) ->
    gen_server:cast(?MODULE, {run, TestConfig}).

%% Gen Server handlers:
handle_cast({run, TestConfig}, State) ->
    lager:info("Running test ~s", [TestConfig]),
    {ok, FileContents} = file:read_file(TestConfig),
    JSON = jsonx:decode(FileContents, [{format, proplist}]),
    Server = proplists:get_value(<<"server">>, JSON),
    Host = proplists:get_value(<<"host">>, Server),
    Port = proplists:get_value(<<"port">>, Server),
    Endpoint = proplists:get_value(<<"endpoint">>, Server),
    ServerMetadata = proplists:get_value(<<"metadata">>, Server),
    Phases = proplists:get_value(<<"phases">>, JSON),
    Sessions = proplists:get_value(<<"sessions">>, JSON),
    plan_phases(Phases),
    {noreply, State#manager_state{server = prepare_server(Host, Port, Endpoint, ServerMetadata),
                                  sessions = prepare_sessions(Sessions),
                                  phases = prepare_phases(Phases)}};

handle_cast({plan_phases, Phases}, State) ->
    lists:map(fun(Phase) ->
                      Name = proplists:get_value(<<"name">>, Phase),
                      Users = proplists:get_value(<<"users">>, Phase),
                      StartTime = proplists:get_value(<<"start_time">>, Phase),
                      Duration = proplists:get_value(<<"duration">>, Phase),
                      Sessions = proplists:get_value(<<"user_sessions">>, Phase),
                      plan_phase(Name, StartTime, make_interval(1, Duration, Users), Sessions)
              end,
              Phases),
    {noreply, State}.

handle_call(Request, From, State) ->
    lager:warning("Unhandled Manager call change."),
    {reply, ok, State}.

handle_info({timeout, _Ref, {run_phase, Phase, {Max, Bulk, Timeout}, Sessions}}, State) ->
    lager:notice("Running Flood phase ~s: ~p users every ~p msecs (~p max).", [Phase, Bulk, Timeout, Max]),
    run_phase(Phase, Max, Bulk, Timeout, Sessions),
    {noreply, State};

handle_info({timeout, _Ref, {spawn_clients, Phase, Max, Bulk, Timeout, Sessions}}, State) ->
    {Session, NewState} = random_session(Sessions, State),
    Metadata = build_metadata(Phase, NewState),
    Url = proplists:get_value(<<"url">>, State#manager_state.server),
    flood_serv:spawn_clients(Max, Bulk, Timeout, [Url, Session, Metadata]),
    run_phase(Phase, Max - Bulk, Bulk, Timeout, Sessions),
    {noreply, NewState}.

code_change(_OldVsn, State, _Extra) ->
    lager:warning("Unhandled Manager code change."),
    {ok, State}.

%% Internal functions:
plan_phases(Phases) ->
    gen_server:cast(?MODULE, {plan_phases, Phases}).

plan_phase(Name, StartTime, Interval, Sessions) ->
    erlang:start_timer(StartTime, self(), {run_phase, Name, Interval, Sessions}).

run_phase(Phase, Max, Bulk, Timeout, Sessions) ->
    case Max > 0 of
        true  -> erlang:start_timer(Timeout, self(), {spawn_clients, Phase, Max, Bulk, Timeout, Sessions});
        false -> ok %% NOTE End of phase reached.
    end.

%% prepare_sessions(Sessions) ->
%%     lists:map(fun(Session) ->
%%                       Name = proplists:get_value(<<"name">>, Session),
%%                       Weight = proplists:get_value(<<"weight">>, Session),
%%                       Inherits = proplists:get_value(<<"inherits">>, Session, []),
%%                       {Name, Weight, Session}
%%               end,
%%               Sessions).


prepare_sessions(Sessions) ->
    prepare_sessions(Sessions, []).

prepare_sessions([], Acc) ->
    Acc;

prepare_sessions([Session | Sessions], Acc) ->
    Name = proplists:get_value(<<"name">>, Session),
    case lists:keyfind(Name, 1, Acc) of
        false ->
            %% NOTE Session need so prepare its base sessions first.
            %% FIXME This badly needs a top sort.
            Weight = proplists:get_value(<<"weight">>, Session),
            Inherits = proplists:get_value(<<"inherits">>, Session, []),
            NewAcc = prepare_sessions(lists:filter(fun(S) ->
                                                           SName = proplists:get_value(<<"name">>, S),
                                                           lists:member(SName, Inherits)
                                                   end,
                                                   Sessions),
                                      Acc),
            {Dos, Meta} = lists:unzip(lists:map(fun({_N, _W, S}) ->
                                                        {proplists:get_value(<<"do">>, S),
                                                         proplists:get_value(<<"metadata">>, S)}
                                                end,
                                                lists:map(fun(SName) ->
                                                                  lists:keyfind(SName, 1, NewAcc)
                                                          end,
                                                          Inherits))),
            PreparedSession = append_field(<<"metadata">>,
                                           append_field(<<"do">>,
                                                        Session,
                                                        lists:append(Dos)),
                                           lists:append(Meta)),
            prepare_sessions(Sessions, [{Name, Weight, PreparedSession} | NewAcc]);
        _ ->
            %% NOTE Session already prepared.
            prepare_sessions(Sessions, Acc)
    end.

append_field(Field, [{Field, Value} | Rest], Values) ->
    [{Field, Value ++ Values} | Rest];

append_field(_Field, [], _Values) ->
    [];

append_field(Field, [Value | Rest], Values) ->
    [Value | append_field(Field, Rest, Values)].

prepare_phases(Phases) ->
    lists:map(fun(Phase) ->
                      Name = proplists:get_value(<<"name">>, Phase),
                      {Name, Phase}
              end,
              Phases).

prepare_server(Host, Port, Endpoint, Metadata) ->
    [{<<"url">>, {Host, Port, Endpoint}},
     {<<"metadata">>, Metadata}].

make_interval(Bulk, Duration, MaxUsers) ->
    case Duration > (5 * MaxUsers) of
        true  -> {MaxUsers, Bulk, Duration div MaxUsers};
        false -> make_interval(Bulk * 10, Duration * 10, MaxUsers)
    end.

random_session(AllowedSessions, State) ->
    Sessions = lists:map(fun(Name) ->
                                 lists:keyfind(Name, 1, State#manager_state.sessions)
                         end,
                         AllowedSessions),
    TotalWeights = lists:foldl(fun({_Name, Weight, _Session}, Sum) ->
                                       Sum + Weight
                               end,
                               0.0,
                               Sessions),
    Beta = State#manager_state.beta + 2 * TotalWeights * random:uniform(),
    select_session(Beta, Sessions, Sessions, State).

select_session(_Beta, _Left, [], _State) ->
    error;

select_session(Beta, [], AllSessions, State) ->
    select_session(Beta, AllSessions, AllSessions, State);

select_session(Beta, [{_Name, Weight, Session} | Rest], AllSessions, State) ->
    case Weight > Beta of
        true  -> {Session, State#manager_state{beta = Beta}};
        false -> select_session(Beta - Weight, Rest, AllSessions, State)
    end.

build_metadata(PhaseName, State) ->
    Server = State#manager_state.server,
    {Host, Port, Endpoint} = proplists:get_value(<<"url">>, Server),
    ServerMetadata = proplists:get_value(<<"metadata">>, Server),
    Phase = proplists:get_value(PhaseName, State#manager_state.phases),
    Users = proplists:get_value(<<"users">>, Phase),
    StartTime = proplists:get_value(<<"start_time">>, Phase),
    Duration = proplists:get_value(<<"duration">>, Phase),
    PhaseMetadata = proplists:get_value(<<"metadata">>, Phase),
    ServerMetadata ++ [{<<"server.host">>, Host},
                       {<<"server.port">>, Port},
                       {<<"server.endpoint">>, Endpoint},
                       {<<"phase.name">>, PhaseName},
                       {<<"phase.users">>, Users},
                       {<<"phase.start_time">>, StartTime},
                       {<<"phase.duration">>, Duration}
                       | PhaseMetadata].

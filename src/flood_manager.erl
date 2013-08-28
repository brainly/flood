-module(flood_manager).
-behaviour(gen_server).

-export([start_link/0, init/1, terminate/2]).
-export([handle_cast/2, handle_call/3, handle_info/2, code_change/3]).
-export([run/1]).

-import(flood_session_utils, [get_value/2, get_value/3, get_value/4]).
-import(flood_session_utils, [json_subst/2]).

-define(MINIMAL_INTERVAL, 10).

-record(server, {
          url      = undefined :: term(),
          metadata = []        :: list()
         }).
-record(flood_goal, {
          test_time = 0      :: integer(),
          phase     = <<"">> :: binary(),
          schema    = []     :: term()
         }).
-record(flood_phase, {
          start_time     = 0             :: integer(),
          end_time       = 0             :: integer(),
          spawn_interval = 0             :: integer(),
          spawn_bulk     = 0             :: integer(),
          max_users      = 0             :: integer(),
          user_sessions  = []            :: list(),
          goal           = #flood_goal{} :: #flood_goal{},
          metadata       = []            :: list()
         }).
-record(manager_state, {
          test_file = <<"">>    :: binary(),
          server    = #server{} :: #server{},
          phases    = []        :: [#flood_phase{}],
          goals     = []        :: list(),
          sessions  = []        :: list(),
          beta      = 0.0       :: number()
         }).

%% Gen Server callbacks:
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE,[], []).

init([]) ->
    random:seed(erlang:now()),
    {ok, #manager_state{}}.

terminate(Reason, State) ->
    lager:info("Manager terminated:~n- State: ~p~n- Reason: ~p", [State, Reason]),
    ok.

%% External functions:
run(TestConfig) ->
    gen_server:cast(?MODULE, {run, TestConfig}).

%% Gen Server handlers:
handle_cast({run, TestConfig}, State) ->
    lager:notice("Running test ~s", [TestConfig]),
    JSON = read_file(TestConfig),
    Server = get_value(<<"server">>, JSON),
    Phases = get_value(<<"phases">>, JSON),
    Sessions = get_value(<<"sessions">>, JSON),
    schedule_phases(),
    schedule_tests(),
    {noreply, prepare_sessions(Sessions,
                               prepare_phases(Phases,
                                              prepare_server(Server,
                                                             State#manager_state{test_file = TestConfig})))};

handle_cast(schedule_phases, State) ->
    lists:map(fun({Name, Phase}) ->
                      schedule_phase(Name, Phase)
              end,
              State#manager_state.phases),
    {noreply, State};

handle_cast({schedule_phase, Name, Phase = #flood_phase{}}, State) ->
    #flood_phase{max_users = Max,
                 spawn_interval = Interval,
                 spawn_bulk = Bulk,
                 start_time = Start} = Phase,
    lager:notice("Scheduling Flood phase ~s: ~p users every ~p msecs (~p max) starting at ~p ms.",
                 [Name, Bulk, Interval, Max, Start]),
    run_phase(Start, Max, Phase),
    {noreply, State};

handle_cast(schedule_tests, State) ->
    [{_Time, Last} | Goals] = lists:reverse(lists:keysort(1, State#manager_state.goals)),
    lists:map(fun({_T, Goal}) ->
                      schedule_test(Goal)
              end,
              Goals),
    schedule_test(Last, final),
    {noreply, State};

handle_cast({schedule_test, Goal = #flood_goal{}, Halt}, State) ->
    Time = Goal#flood_goal.test_time,
    Name = Goal#flood_goal.phase,
    lager:notice("Scheduling Flood phase ~s test, starting at ~p ms.", [Name, Time]),
    run_test(Time, Goal, Halt),
    {noreply, State}.

handle_call(Request, _From, State) ->
    lager:warning("Unhandled Manager call: ~p.", [Request]),
    {reply, ok, State}.

handle_info({timeout, _Ref, {spawn_clients, Num, Phase = #flood_phase{}}}, State) ->
    #flood_phase{spawn_interval = Interval,
                 spawn_bulk = Bulk,
                 metadata = PhaseMetadata} = Phase,
    {Session, NewState} = random_session(Phase#flood_phase.user_sessions, State),
    Url = NewState#manager_state.server#server.url,
    flood_serv:spawn_clients(Bulk, [Url, Session, PhaseMetadata]),
    run_phase(Interval, Num - Bulk, Phase),
    {noreply, NewState};

handle_info({timeout, _Ref, {run_test, Goal = #flood_goal{}, Halt}}, State) ->
    Name = Goal#flood_goal.phase,
    case jesse:validate_with_accumulator(Goal#flood_goal.schema,
                                         flood:get_stats(),
                                         fun(Field, Error, Rest) ->
                                                 [{Field, Error} | Rest]
                                         end,
                                         [])
    of
        {error, Errors} ->
            lager:notice("Flood phase ~s failed to reach its goal: ~s",
                         [Name, flood_error_utils:pretty_errors(Errors)]),
            stop(1);

        {ok, _Result} when Halt == true ->
            lager:notice("Flood phase ~s reached its goal!", [Name]),
            stop(0);

        {ok, _Result} ->
            lager:notice("Flood phase ~s reached its goal!", [Name])
    end,
    {noreply, State};

handle_info({timeout, _Ref, {halt, Ret}}, State) ->
    FileName = filename:rootname(State#manager_state.test_file) ++ "_flood_result.json",
    flood:dump_stats(FileName),
    halt(Ret).

code_change(_OldVsn, State, _Extra) ->
    lager:warning("Unhandled Manager code change."),
    {ok, State}.

%% Internal functions:
prepare_server(Server, State) ->
    Metadata = get_value(<<"metadata">>, Server),
    Host = get_value(<<"host">>, Server),
    Port = get_value(<<"port">>, Server),
    Endpoint = get_value(<<"endpoint">>, Server),
    Url = {Host, Port, Endpoint},
    S = #server{url = Url,
                metadata = [{<<"server.url">>, Url},
                            {<<"server.host">>, Host},
                            {<<"server.port">>, Port},
                            {<<"server.endpoint">>, Endpoint}
                            | Metadata]},
    State#manager_state{server = S}.

prepare_phases(Phases, State) ->
    P = lists:map(fun ({Name, Phase}) ->
                          ServerMetadata = State#manager_state.server#server.metadata, %% Fuuuugly.
                          PhaseMetadata = get_value(<<"metadata">>, Phase),
                          %% NOTE We store server metadata for later use and make sure,
                          %% NOTE that phase metadata overrides it.
                          Metadata = PhaseMetadata ++ ServerMetadata,
                          Users = get_value(<<"users">>, Phase, Metadata),
                          StartTime = get_value(<<"start_time">>, Phase, Metadata),
                          EndTime = get_value(<<"end_time">>, Phase, Metadata, StartTime),
                          Goal = case get_value(<<"goal">>, Phase, Metadata) of
                                     undefined -> [];
                                     SomeGoal  -> SomeGoal
                                 end,
                          Schema = case is_binary(Goal) of
                                       true  -> N = filename:dirname(State#manager_state.test_file) ++ "/" ++ binary_to_list(Goal),
                                                json_subst(read_file(N), Metadata);
                                       false -> Goal
                                   end,

                          Duration = get_value(<<"spawn_duration">>, Phase, Metadata),
                          Sessions = get_value(<<"user_sessions">>, Phase, Metadata),
                          {Max, Bulk, Interval} = make_interval(Duration, Users),
                          {Name, #flood_phase{
                             start_time = StartTime,
                             end_time = EndTime,
                             spawn_interval = Interval,
                             spawn_bulk = Bulk,
                             max_users = Max,
                             user_sessions = Sessions,
                             goal = #flood_goal{
                               phase = Name,
                               test_time = EndTime,
                               schema = Schema
                              },
                             metadata = [{<<"phase.name">>, Name},
                                         {<<"phase.users">>, Users},
                                         {<<"phase.user_sessions">>, Sessions},
                                         {<<"phase.start_time">>, StartTime},
                                         {<<"phase.spawn_duration">>, Duration},
                                         {<<"phase.end_time">>, EndTime},
                                         {<<"phase.goal">>, Goal}
                                         | Metadata]
                            }}
                  end,
                  Phases),
    G = lists:map(fun ({_Name, Phase}) ->
                          Goal = Phase#flood_phase.goal,
                          TestTime = Goal#flood_goal.test_time,
                          {TestTime, Goal}
                  end,
                  P),
    State#manager_state{phases = P, goals = G}.

prepare_sessions(Sessions, State = #manager_state{}) ->
    State#manager_state{sessions = prepare_sessions_iter(Sessions, [])}.

prepare_sessions_iter([], Acc) ->
    Acc;

prepare_sessions_iter([{Name, Session} | Sessions], Acc) ->
    case lists:keyfind(Name, 1, Acc) of
        false ->
            %% NOTE Session needs to prepare its base sessions first.
            %% FIXME This badly needs a top sort.
            Weight = get_value(<<"weight">>, Session),
            Extends = case get_value(<<"extends">>, Session) of
                          undefined    -> [];
                          SomeSessions -> SomeSessions
                      end,
            NewAcc = prepare_sessions_iter(lists:filter(fun({N, _S}) ->
                                                                lists:member(N, Extends)
                                                        end,
                                                        Sessions),
                                           Acc),
            {Dos, Meta} = lists:unzip(lists:map(fun({_N, _W, S}) ->
                                                        {get_value(<<"do">>, S),
                                                         get_value(<<"metadata">>, S)}
                                                end,
                                                lists:map(fun(N) ->
                                                                  lists:keyfind(N, 1, NewAcc)
                                                          end,
                                                          Extends))),
            PreparedSession = append_field(<<"metadata">>,
                                           prepend_field(<<"do">>,
                                                         Session,
                                                         lists:append(Dos)),
                                           lists:append(Meta)),
            prepare_sessions_iter(Sessions, [{Name, Weight, PreparedSession} | NewAcc]);
        _ ->
            %% NOTE Session already prepared.
            prepare_sessions_iter(Sessions, Acc)
    end.

schedule_phases() ->
    gen_server:cast(?MODULE, schedule_phases).

schedule_phase(Name, Phase = #flood_phase{}) ->
    gen_server:cast(?MODULE, {schedule_phase, Name, Phase}).

run_phase(Time, Num, Phase = #flood_phase{}) ->
    case Num > 0 of
        true  -> erlang:start_timer(Time, self(), {spawn_clients, Num, Phase});
        false -> ok
    end.

schedule_tests() ->
    gen_server:cast(?MODULE, schedule_tests).

schedule_test(Goal) ->
    gen_server:cast(?MODULE, {schedule_test, Goal, false}).

schedule_test(Goal, final) ->
    gen_server:cast(?MODULE, {schedule_test, Goal, true}).

run_test(Time, Goal, Halt) ->
    erlang:start_timer(Time, self(), {run_test, Goal, Halt}).

append_field(Field, [{Field, Value} | Rest], Values) ->
    [{Field, Value ++ Values} | Rest];

append_field(_Field, [], _Values) ->
    [];

append_field(Field, [Value | Rest], Values) ->
    [Value | append_field(Field, Rest, Values)].

prepend_field(Field, [{Field, Value} | Rest], Values) ->
    [{Field, Values ++ Value} | Rest];

prepend_field(_Field, [], _Values) ->
    [];

prepend_field(Field, [Value | Rest], Values) ->
    [Value | append_field(Field, Rest, Values)].

make_interval(Duration, MaxUsers) ->
    make_interval(1, Duration, MaxUsers).

make_interval(_Bulk, _Duration, 0) ->
    {0, 0, 0};

make_interval(Bulk, Duration, MaxUsers) ->
    case Duration >= (?MINIMAL_INTERVAL * MaxUsers) of
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

read_file(FileName) ->
    {ok, FileContents} = file:read_file(FileName),
    jsonx:decode(FileContents, [{format, proplist}]).

stop(Ret) ->
    erlang:start_timer(100, self(), {halt, Ret}).

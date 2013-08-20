-module(flood_manager).
-behaviour(gen_server).

-export([start_link/0, init/1, terminate/2]).
-export([handle_cast/2, handle_call/3, handle_info/2, code_change/3]).
-export([run/1]).

-compile(export_all).

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
    Host = binary_to_list(proplists:get_value(<<"host">>, Server)),
    Port = proplists:get_value(<<"port">>, Server),
    Endpoint = binary_to_list(proplists:get_value(<<"endpoint">>, Server)),
    Phases = proplists:get_value(<<"phases">>, JSON),
    plan_phases(Phases),
    Sessions = prepare_sessions(proplists:get_value(<<"sessions">>, JSON)),
    {noreply, State#manager_state{server = {Host, Port, Endpoint},
                                  sessions = Sessions,
                                  phases = Phases}};

handle_cast({plan_phases, Phases}, State) ->
    lists:map(fun(Phase) ->
                      Name = proplists:get_value(<<"phase_name">>, Phase),
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

handle_info({timeout, _Ref, {run_phase, Name, {Max, Bulk, Timeout}, Sessions}}, State) ->
    lager:info("Running Flood phase ~s: ~p users every ~p msecs (~p max).", [Name, Bulk, Timeout, Max]),
    run_phase(Max, Bulk, Timeout, Sessions),
    {noreply, State};

handle_info({timeout, _Ref, {spawn_clients, Max, Bulk, Timeout, Sessions}}, State) ->
    {Session, NewState} = random_session(Sessions, State),
    flood_serv:spawn_clients(Max, Bulk, Timeout, [State#manager_state.server, Session]),
    run_phase(Max - Bulk, Bulk, Timeout, Sessions),
    {noreply, NewState}.

code_change(_OldVsn, State, _Extra) ->
    lager:warning("Unhandled Manager code change."),
    {ok, State}.

%% Internal functions:
plan_phases(Phases) ->
    gen_server:cast(?MODULE, {plan_phases, Phases}).

plan_phase(Name, StartTime, Interval, Sessions) ->
    erlang:start_timer(StartTime, self(), {run_phase, Name, Interval, Sessions}).

run_phase(Max, Bulk, Timeout, Sessions) ->
    case Max > 0 of
        true  -> erlang:start_timer(Timeout, self(), {spawn_clients, Max, Bulk, Timeout, Sessions});
        false -> ok %% NOTE Phase ended
    end.

prepare_sessions(Sessions) ->
    lists:map(fun(Session) ->
                      Name = proplists:get_value(<<"session_name">>, Session),
                      Weight = proplists:get_value(<<"weight">>, Session),
                      {Name, Weight, Session}
              end,
              Sessions).

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

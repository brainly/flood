-module(flood).

-export([start/0, start/1, stop/0]).

-export([get_env/1]).

-export([run/1]).

-export([inc/1, inc/2, dec/1, dec/2, set/2, update/2]).
-export([new_counter/1, get_counter/1, new_histogram/1, get_histogram/1]).
-export([get_stats/0, stats/0, dump_stats/1]).

start() ->
    start([]).

start(Args) ->
    crypto:start(), % Used by WebSocket client backend
    ssl:start(),    % To be used by WebSocket client backend
    lager:start(),
    application:start(folsom),
    init_counters(),
    ibrowse:start(),
    application:start(flood),
    case Args of
        [FileName] -> flood_manager:run(atom_to_list(FileName));
        []         -> ok
    end.

stop() ->
    application:stop(folsom),
    application:stop(flood).

get_env(Key) ->
    {ok, Value} = application:get_env(?MODULE, Key),
    Value.

run(TestFile) ->
    flood_manager:run(TestFile).

new_counter(Name) ->
    ok = folsom_metrics:new_counter(Name).

get_counter(Name) ->
    folsom_metrics:get_metric_value(Name).

inc(Name) ->
    inc(Name, 1).

inc(Name, Value) ->
    folsom_metrics:notify(Name, {inc, Value}, counter).

dec(Counter) ->
    dec(Counter, 1).

dec(Name, Value) ->
    folsom_metrics:notify(Name, {dec, Value}, counter).

set(Name, Value) ->
    folsom_metrics:notify(Name, clear, counter),
    inc(Name, Value).

new_histogram(Name) ->
    ok = folsom_metrics:new_histogram(Name, slide_uniform, {60, 100}). %% FIXME Use more sensible values.

get_histogram(Name) ->
    folsom_metrics:get_histogram_statistics(Name).

update(Name, Value) ->
    case folsom_metrics:metric_exists(Name) of
        true  -> ok;
        false -> new_histogram(Name)
    end,
    folsom_metrics:notify(Name, Value).

stats() ->
    {Counters, Histograms} = get_metrics(),
    jsonx:encode([{counters, lists:map(fun(Counter) ->
                                               {Counter, get_counter(Counter)}
                                       end,
                                       Counters)},
                  {timers, lists:map(fun(Histogram) ->
                                             {Histogram, fix(get_histogram(Histogram))}
                                     end,
                                     Histograms)}]).

get_stats() ->
    jsonx:decode(stats(), [{format, proplist}]).

dump_stats(Filename) ->
    ok = file:write_file(Filename, stats()).

%% Internal functions:
init_counters() ->
    new_counter(disconnected_users),
    new_counter(connected_users),
    new_counter(terminated_users),
    new_counter(all_users),
    new_counter(alive_users),
    new_counter(ws_incomming),
    new_counter(ws_outgoing),
    new_counter(http_incomming),
    new_counter(http_outgoing).

get_metrics() ->
    MT = lists:map(fun(M) ->
                           {M, Info} = folsom_ets:get_info(M),
                           {M, proplists:get_value(type, Info)}
                   end,
                   folsom_metrics:get_metrics()),
    split(MT, [], []).

split([], Counters, Histograms) ->
    {Counters, Histograms};

split([{Metric, histogram} | Rest], Counters, Histograms) ->
    split(Rest, Counters, [Metric | Histograms]);

split([{Metric, counter} | Rest], Counters, Histograms) ->
    split(Rest, [Metric | Counters], Histograms).

fix([]) ->
    [];

fix([{percentile, Values} | Rest]) ->
    Fixed = lists:map(fun({N, V}) ->
                              {integer_to_binary(N), V}
                      end, Values),
    [{percentile, Fixed} | fix(Rest)];

fix([{histogram, Values} | Rest]) ->
    Fixed = lists:map(fun({N, V}) ->
                              {integer_to_binary(N), V}
                      end, Values),
    [{histogram, Fixed} | fix(Rest)];


fix([Ok | Rest]) ->
    [Ok | fix(Rest)].

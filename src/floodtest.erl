-module(floodtest).
-export([start/2]).

start(Filename, Wait) ->
    inets:start(),
    spawn(fun()-> loadurls(Filename, fun(U)->
                                        floodfsm:start_link(U, 10)
                                     end, Wait) end).

for_each_line_in_file(Name, Proc, Mode, Accum0) ->
    {ok, Device} = file:open(Name, Mode),
    for_each_line(Device, Proc, Accum0).

for_each_line(Device, Proc, Accum) ->
    case io:get_line(Device, "") of
        eof  -> file:close(Device), Accum;
        Line -> NewAccum = Proc(Line, Accum),
                    for_each_line(Device, Proc, NewAccum)
    end.

loadurls(Filename, Callback, Wait) ->
    for_each_line_in_file(Filename,
        fun(Line, List) ->
            Callback(string:strip(Line, right, $\n)),
            receive
            after Wait ->
                noop
            end,
            List
        end,
        [read], []).

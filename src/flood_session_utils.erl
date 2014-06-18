-module(flood_session_utils).
-author('kajetan.rzepecki@zadane.pl').

-export([json_match/2, json_subst/2, combine/2, sio_ack/1, sio_type/1, sio_opcode/1, get_value/2, get_value/3, get_value/4]).

-include("socketio.hrl").

%% Some helper functions:
json_match(Subject, Pattern) ->
    case catch json_do_match(Subject, Pattern) of
        nomatch -> nomatch;
        Matches -> {match, Matches}
    end.

json_subst([], _Metadata) ->
    [];

json_subst([{Name, Value} | Rest], Metadata) ->
    [{lookup(Name, Metadata), json_subst(Value, Metadata)} | json_subst(Rest, Metadata)];

json_subst([Value | Rest], Metadata) ->
    [json_subst(Value, Metadata) | json_subst(Rest, Metadata)];

json_subst(JSON, Metadata) ->
    lookup(JSON, Metadata).

combine({reply, A, StateA}, {reply, B, _StateB}) ->
    {reply, B ++ A, StateA};

combine({reply, Replies, StateA}, {noreply, _StateB}) ->
    {reply, Replies, StateA};

combine({noreply, StateA}, {reply, Replies, _StateB}) ->
    {reply, Replies, StateA};

combine({noreply, StateA}, _) ->
    {noreply, StateA};

combine({stop, Reason, StateA}, _) ->
    {stop, Reason, StateA}.

sio_ack(Id) ->
    try binary:last(Id) of
        $+ -> {client, binary_to_integer(binary:part(Id, 0, byte_size(Id)-1))};
        _  -> {server, binary_to_integer(Id)}
    catch
        error:_ -> undefined
    end.

sio_type(Opcode) ->
    proplists:get_value(Opcode, lists:zip(?MESSAGE_OPCODES, ?MESSAGE_TYPES), error).

sio_opcode(Type) ->
    proplists:get_value(Type, lists:zip(?MESSAGE_TYPES, ?MESSAGE_OPCODES), <<"7">>).

get_value(What, Where) ->
    proplists:get_value(What, Where).

get_value(What, Where, Metadata) ->
    get_value(What, Where, Metadata, undefined).

get_value(What, Where, Metadata, Default) ->
    json_subst(proplists:get_value(What, Where, Default), Metadata).

%% Helper functions:
lookup(What, []) ->
    What;

lookup(What, Metadata) ->
    case is_variable(What) of
        {true, Variable} -> proplists:get_value(Variable, Metadata);
        false            -> What
    end.

is_variable(<<"$", Variable/binary>>) ->
    {true, Variable};

is_variable(_What) ->
    false.

json_do_match([], []) ->
    [];

json_do_match(_, []) ->
    throw(nomatch);

json_do_match([], _) ->
    throw(nomatch);

json_do_match(Subject, [{Name, Val}]) ->
    %% NOTE Can't just match against [] since it might be an actual JSON array.
    case proplists:get_value(Name, Subject) of
        undefined -> throw(nomatch);
        Value     -> json_do_match(Value, Val)
    end;

json_do_match(Subject, [{Name, Val} | Rest]) ->
    case proplists:get_value(Name, Subject) of
        undefined -> throw(nomatch);
        Value     -> json_do_match(Value, Val) ++ json_do_match(Subject, Rest)
    end;

json_do_match([Value | Values], [Pattern | Patterns]) ->
    json_do_match(Value, Pattern) ++ json_do_match(Values, Patterns);

json_do_match(Value, Value) ->
    [];

json_do_match(Subject, Pattern) ->
    case is_variable(Pattern) of
        {true, Variable} -> [{Variable, Subject}];
        false            -> throw(nomatch)
    end.

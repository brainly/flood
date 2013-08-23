-module(flood_session_utils).

-include("socketio.hrl").

-compile(export_all).

-export([json_match/2, json_subst/2, combine/2, sio_type/1, sio_opcode/1]).

%% Some helper functions:
json_match(Subject, Subject) ->
    true;

json_match(Subject, [{Name, Value}]) ->
    %% NOTE Can't match against [] since it might be an actual JSON array.
    case proplists:get_value(Name, Subject) of
        undefined -> false;
        Value     -> true;
        Other     -> json_match(Other, Value)
    end;

json_match(Subject, [{Name, Value} | Rest]) ->
    case proplists:get_value(Name, Subject) of
        undefined -> false;
        Value     -> true andalso json_match(Subject, Rest);
        Other     -> json_match(Other, Value) andalso json_match(Subject, Rest)
    end;

json_match(_Subject, _Pattern) ->
    false.

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

sio_type(Opcode) ->
    proplists:get_value(Opcode, lists:zip(?MESSAGE_OPCODES, ?MESSAGE_TYPES), error).

sio_opcode(Type) ->
    proplists:get_value(Type, lists:zip(?MESSAGE_TYPES, ?MESSAGE_OPCODES), <<"7">>).

%% Helper functions:
lookup(<<"$", What/binary>>, Metadata) ->
    proplists:get_value(What, Metadata);

lookup(What, _Metadata) ->
    What.

-module(flood_error_utils).

-export([pretty_error/1, pretty_errors/1]).

%% External functions:
pretty_errors([]) ->
    [];

pretty_errors([{Field, Error}]) ->
    "\"" ++ Field ++ "\": " ++ pretty_error(Error) ++ ".";

pretty_errors([{Field, Error} | Errors]) ->
    "\"" ++ Field ++ "\": " ++ pretty_error(Error) ++ ", " ++ pretty_errors(Errors).

pretty_error({data_invalid, _Schema, wrong_length, Value}) ->
    lists:flatten(io_lib:format("value \"~s\" is of a wrong length", [to_string(Value)]));

pretty_error({data_invalid, _Schema, {not_unique, Value}, Values}) ->
    lists:flatten(io_lib:format("value \"~s\" is not unique in ~s", [to_string(Value), to_string(Values)]));

pretty_error({data_invalid, _Schema, {missing_required_property, Value}, _Values}) ->
    lists:flatten(io_lib:format("required property \"~s\" is missing", [to_string(Value)]));

pretty_error({data_invalid, _Schema, wrong_type, Value}) ->
    lists:flatten(io_lib:format("value \"~s\" is of a wrong type", [to_string(Value)]));

pretty_error({data_invalid, _Schema, not_in_range, Value}) ->
    lists:flatten(io_lib:format("value \"~s\" is outside of accepted range", [to_string(Value)]));

pretty_error(Error) ->
    lists:flatten(io_lib:format("~p", [Error])).

%% Internal functions:
to_string(Str = [Int | _Rest]) when is_integer(Int) ->
    Str;

to_string(Value) when is_binary(Value) ->
    binary_to_list(Value);

to_string(Value) ->
    lists:flatten(io_lib:format("~s", [jsonx:encode(Value)])).

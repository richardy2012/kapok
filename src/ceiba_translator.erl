%% Translate Ceiba AST to Erlang Abstract Format.
-module(ceiba_translator).

-export([translate/1]).
-import(ceiba_scanner,
        [token_line/1,
         location_line/1]).

%% Operators
translate({Op, Meta, Number}) when Op == '+', Op == '-' ->
    {op, location_line(Meta), Op, translate(Number)};

%% Containers

translate({binary, Meta, Args}) ->
    ceiba_binary:translate(Meta, Args);
translate({list, _Meta, [Head|Tail]}) ->
    translate_list([Head|Tail], []);
    %%{list, Meta, [Head|Tail]};
translate(List) when is_list(List) ->
    [translate(E) || E <- List];

%% literals

%% number

%% integer
translate({number, Meta, Value}) when is_integer(Value) ->
    {integer, location_line(Meta), Value};
%% float
translate({number, Meta, Value}) when is_float(Value) ->
    {float, location_line(Meta), Value};

%% atom
translate({atom, Meta, Value}) ->
    {atom, location_line(Meta), Value};

%% list string
translate({list_string, Meta, Value}) ->
    {string, location_line(Meta), binary_to_list(Value)};
%% tuple
translate({tuple, Meta, Value}) ->
    {tuple, location_line(Meta), Value}.




%% Helpers
translate_list([H|T], Acc) ->
    TH = translate(H),
    translate_list(T, [TH|Acc]);
translate_list([], Acc) ->
    build_list(Acc, {nil, 0}).

build_list([H|T], Acc) ->
    build_list(T, {cons, 0, H, Acc});
build_list([], Acc) ->
    Acc.



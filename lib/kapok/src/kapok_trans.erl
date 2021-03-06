%% Translate Kapok AST to Erlang Abstract Format.
-module(kapok_trans).
-export([translate/2,
         map_vars/4,
         translate_def_arg/2,
         translate_def_args/2,
         translate_guard/2,
         translate_body/3,
         translate_remote_call/5,
         quote/2,
         eval/2,
         construct_new_args/5,
         format_error/1]).
-import(kapok_scanner, [token_meta/1, token_symbol/1, token_text/1]).
-import(kapok_parser, [is_identifier/1, is_plain_dot/1, plain_dot_name/1, plain_dot_mf/1]).
-import(kapok_trans_collection, [build_tuple/2,
                                 build_map_from/2,
                                 build_list/1,
                                 translate_tuple/3,
                                 translate_map/3,
                                 translate_set/3,
                                 translate_list/2,
                                 translate_cons_list/3
                               ]).
-import(kapok_trans_special_form, [translate_attribute/4,
                                   translate_let/4,
                                   translate_dot_let/4,
                                   translate_do/3,
                                   translate_case/5,
                                   translate_fn/3,
                                   translate_fn/4,
                                   translate_fn/5,
                                   translate_fn/6,
                                   translate_send/4,
                                   translate_receive/3,
                                   translate_try/3
                                  ]).
-include("kapok.hrl").

%% a list of ast
translate(List, Ctx) when is_list(List) ->
  lists:mapfoldl(fun translate/2, Ctx, List);

%% literals

%% number
%% integer
translate({number, Meta, Number}, Ctx) when is_integer(Number) ->
  {{integer, ?line(Meta), Number}, Ctx};
%% float
translate({number, Meta, Number}, Ctx) when is_float(Number) ->
  {{float, ?line(Meta), Number}, Ctx};

%% Operators
translate({Op, Meta, Number}, Ctx) when ?is_op(Op) ->
  {Erl, TCtx} = translate(Number, Ctx),
  {{op, ?line(Meta), Op, Erl}, TCtx};

%% keyword and atom
translate({Category, Meta, Atom}, Ctx) when Category == keyword; Category == atom ->
  {{atom, ?line(Meta), Atom}, Ctx};

%% Identifiers
translate({identifier, Meta, Id}, #{context := Context} = Ctx) ->
  %% TODO if Id is a function name
  %% search ctx to check whether identifier is a variable
  {Name1, Ctx1} = case Context of
                    fn_pattern ->
                      case kapok_ctx:get_var_current_scope(Meta, Ctx, Id) of
                        {ok, Name} -> {Name, Ctx};
                        error -> kapok_ctx:add_var(Meta, Ctx, Id)
                      end;
                    case_pattern ->
                      case kapok_ctx:get_var(Meta, Ctx, Id) of
                        {ok, Name} -> {Name, Ctx};
                        error -> kapok_ctx:add_var(Meta, Ctx, Id)
                      end;
                    let_pattern ->
                      kapok_ctx:add_let_var(Meta, Ctx, Id);
                    dot_let_pattern ->
                      kapok_ctx:add_dot_let_var(Meta, Ctx, Id);
                    _ ->
                      case kapok_ctx:get_var(Meta, Ctx, Id) of
                        {ok, Name} -> {Name, Ctx};
                        error -> kapok_error:compile_error(Meta, ?m(Ctx, file),
                                                           "unable to resolve var: ~p", [Id])
                      end
                  end,
  {to_var(Meta, Name1), Ctx1};

%% binary string
translate({binary_string, _Meta, Binary}, Ctx) ->
  translate(Binary, Ctx);

%% list string
translate({list_string, Meta, Binary}, Ctx) ->
  {{string, ?line(Meta), binary_to_list(Binary)}, Ctx};

%% Collections

%% bitstring
translate({bitstring, Meta, Arg}, Ctx) ->
  kapok_trans_bitstring:translate(Meta, Arg, Ctx);

%% tuple
translate({tuple, Meta, Arg}, Ctx) ->
  translate_tuple(Meta, Arg, Ctx);

%% map
translate({map, Meta, Arg}, Ctx) ->
  translate_map(Meta, Arg, Ctx);

%% set
translate({set, Meta, Arg}, Ctx) ->
  translate_set(Meta, Arg, Ctx);

%% list
translate({literal_list, _Meta, List}, Ctx) ->
  translate_list(List, Ctx);

translate({cons_list, _Meta, {Head, Tail}}, Ctx) ->
  translate_cons_list(Head, Tail, Ctx);

%% special forms
%% let
translate({list, Meta, [{identifier, _, 'let'}, {C, _, Args} | Body]}, Ctx) when ?is_list(C) ->
  translate_let(Meta, Args, Body, Ctx);

%% do
translate({list, Meta, [{identifier, _, 'do'} | Exprs]}, Ctx) ->
  translate_do(Meta, Exprs, Ctx);

%% case
translate({list, Meta, [{identifier, _, 'case'}, Expr, Clause | Left]}, Ctx) ->
  translate_case(Meta, Expr, Clause, Left, Ctx);

%% logical operators: not, and, or xor
%% short-circuit operators: andalso, orelse
translate({list, Meta, [{identifier, _, Op}, Expr]}, Ctx) when Op == 'op-not' ->
  {TExpr, TCtx} = translate(Expr, Ctx),
  {{op, ?line(Meta), op_type(Op), TExpr}, TCtx};
translate({list, _Meta, [{identifier, _, Op}, Expr]}, Ctx)
    when ?is_var_arg_op(Op); ?is_short_circuit_op(Op) ->
  translate(Expr, Ctx);
translate({list, Meta, [{identifier, _, Op}, Left, Right]}, Ctx)
    when ?is_var_arg_op(Op); ?is_short_circuit_op(Op); ?is_list_op(Op) ->
  {TLeft, TCtx1} = translate(Left, Ctx),
  {TRight, TCtx2} = translate(Right, TCtx1),
  {{op, ?line(Meta), op_type(Op), TLeft, TRight}, TCtx2};
translate({list, Meta, [{identifier, OpMeta, Op} = OpAst, Left, Right | T]}, Ctx)
    when ?is_var_arg_op(Op) ->
  translate({list, Meta, [OpAst, {list, OpMeta, [OpAst, Left, Right]} | T]}, Ctx);
translate({list, Meta, [{identifier, OpMeta, Op} = OpAst, Left, Right | T]}, Ctx)
    when ?is_short_circuit_op(Op) ->
  translate({list, Meta, [OpAst, Left, {list, OpMeta, [OpAst, Right | T]}]}, Ctx);

%% fn
translate({list, Meta, [{identifier, _, 'fn'}, {C, _, Id}, {number, _, Arity}]}, Ctx)
    when ?is_keyword_or_atom(C) ->
  FunArity = {Id, Arity},
  case kapok_dispatch:find_local_function(FunArity, Ctx) of
    {Id, Arity, _P} ->
      %% The fun, arity must match `Id', `Arity'
      translate_fn(Meta, Id, Arity, Ctx);
    _ ->
      %% check whether it's an imported function/macro
      {R, Ctx1} = kapok_dispatch:find_imported_local_function(Meta, FunArity, Ctx),
      case R of
        {_M, _F, Number, _P} = MFAP ->
          Error = {invalid_fn_local_imported, {{Id, Number}, MFAP}},
          kapok_error:form_error(Meta, ?m(Ctx1, file), ?MODULE, Error);
        _ ->
          throw({unresolved_local_call, FunArity, Meta})
      end
    end;
translate({list, Meta, [{identifier, _, 'fn'} = FnAst,
                        {C, MetaId, Id},
                        {number, _, _} = ArityAst]},
          Ctx)
    when ?is_id(C) ->
  case kapok_ctx:get_var(Meta, Ctx, Id) of
    {ok, _Name} ->
      Error = {invalid_fn_local_var, {Id}},
      kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, Error);
    _ ->
      translate({list, Meta, [FnAst, {atom, MetaId, Id}, ArityAst]}, Ctx)
  end;
translate({list, Meta, [{identifier, _, 'fn'},
                        {C1, Meta1, Module} = ModuleAst,
                        {C2, Meta2, Fun} = FunAst,
                        {C3, _, _} = ArityAst]},
          Ctx)
    when ?is_local_id(C1), ?is_local_id(C2), ?is_number(C3) ->
  case is_identifier(ModuleAst) of
    true ->
      case kapok_ctx:get_var(Meta1, Ctx, Module) of
        {ok, _} ->
          FunAst1 = case is_identifier(FunAst) of
                      true ->
                        case kapok_ctx:get_var(Meta2, Ctx, Fun) of
                          {ok, _} -> FunAst;
                          error -> {atom, Meta2, Fun}
                        end;
                      false ->
                        {atom, Meta2, Fun}
                    end,
          translate_fn(Meta, ModuleAst, FunAst1, ArityAst, Ctx);
        error ->
          translate_remote_fn(Meta, {atom, Meta1, Module}, FunAst, ArityAst, Ctx)
      end;
    false ->
      translate_remote_fn(Meta, {atom, Meta1, Module}, FunAst, ArityAst, Ctx)
  end;
translate({list, Meta, [{identifier, _, 'fn'},
                        {C1, Meta1, _} = Dot,
                        {C2, Meta2, Fun} = FunAst,
                        {number, _, _} = ArityAst]},
          Ctx)
    when ?is_dot(C1), ?is_local_id(C2) ->
  case is_plain_dot(Dot) of
    true ->
      ModuleAst = {atom, Meta1, plain_dot_name(Dot)},
      FunAst1 = case is_identifier(FunAst) of
                  true ->
                    case kapok_ctx:get_var(Meta2, Ctx, Fun) of
                      {ok, _} -> FunAst;
                      error -> {atom, Meta2, Fun}
                    end;
                  false ->
                    {atom, Meta2, Fun}
                end,
      translate_fn(Meta, ModuleAst, FunAst1, ArityAst, Ctx);
    false ->
      kapok_error:compile_error(Meta, ?m(Ctx, file), "invalid dot expression ~p for fn", [Dot])
  end;
translate({list, Meta, [{identifier, _, 'fn'},
                        {identifier, _, _} = Id,
                        {literal_list, _, _} = Args,
                        {list, _, [{keyword_when, _, _} | _]} = Guard | Body]},
          Ctx) ->
  translate_fn(Meta, Id, Args, Guard, Body, Ctx);
translate({list, Meta, [{identifier, _, 'fn'},
                        {identifier, _, _} = Id,
                        {literal_list, _, _} = Args | Body]},
          Ctx) ->
  translate_fn(Meta, Id, Args, [], Body, Ctx);
translate({list, Meta, [{identifier, _, 'fn'}, {identifier, _, _} = Id | Exprs]}, Ctx) ->
  translate_fn(Meta, Id, Exprs, Ctx);
translate({list, Meta, [{identifier, _, 'fn'}, {literal_list, _, _} = Args,
                        {list, _, [{keyword_when, _, _} | _]} = Guard | Body]}, Ctx) ->
  translate_fn(Meta, Args, Guard, Body, Ctx);
translate({list, Meta, [{identifier, _, 'fn'}, {literal_list, _, _} = Args | Body]}, Ctx) ->
  translate_fn(Meta, Args, [], Body, Ctx);
translate({list, Meta, [{identifier, _, 'fn'} | Exprs]}, Ctx) ->
  translate_fn(Meta, Exprs, Ctx);

%% send
translate({list, Meta, [{identifier, _, 'send'}, Pid, Message]}, Ctx) ->
  translate_send(Meta, Pid, Message, Ctx);

%% receive
translate({list, Meta, [{identifier, _, 'receive'} | Clauses]}, Ctx) ->
  translate_receive(Meta, Clauses, Ctx);

%% try catch after block
translate({list, Meta, [{identifier, _, 'try'} | Exprs]}, Ctx) ->
  translate_try(Meta, Exprs, Ctx);

%% Erlang Attribute Forms

%% behaviour
translate({list, Meta, [{identifier, _, Form}, {Category, _, _} = NameAst]}, #{def_kind := Kind} = Ctx)
    when ?is_behaviour(Form), ?is_id_or_dot(Category), ?is_attr(Kind) ->
  Name = plain_dot_name(NameAst),
  translate_attribute(Meta, Form, Name, Ctx);

%% user-defined attribute
translate({list, Meta, [{identifier, _, Form}, {C1, _, Attribute}, Value]},
          #{def_kind := Kind} = Ctx)
    when ?is_attribute(Form), ?is_id(C1), ?is_attr(Kind) ->
  {EValue, ECtx} = kapok_compiler:eval_ast(Value, Ctx),
  translate_attribute(Meta, Attribute, EValue, ECtx);

%% List

%% local call
translate({list, Meta, [{identifier, Meta1, Id} | Args]}, Ctx) ->
  case kapok_ctx:get_var(Meta, Ctx, Id) of
    {ok, Name} ->
      %% local variable
      TF = to_var(Meta1, Name),
      {TArgs, TCtx1} = translate_args(Args, Ctx),
      translate_local_call(Meta, TF, TArgs, TCtx1);
    error ->
      translate({list, Meta, [{atom, Meta1, Id} | Args]}, Ctx)
  end;
translate({list, Meta, [{C, _, Id} | Args]}, Ctx) when ?is_keyword_or_atom(C) ->
  {TArgs, TCtx1} = translate_args(Args, Ctx),
  Arity = length(TArgs),
  FunArity = {Id, Arity},
  case kapok_dispatch:find_local_function(FunArity, TCtx1) of
    {F2, A2, P2} ->
      translate_local_call(Meta, F2, A2, P2, Arity, TArgs, TCtx1);
    false ->
      %% check whether it's an imported function/macro
      {R3, TCtx2} = kapok_dispatch:find_imported_local_function(Meta, FunArity, TCtx1),
      case R3 of
        {M3, F3, A3, P3} ->
          translate_remote_call(Meta, M3, F3, A3, P3, Arity, TArgs, TCtx2);
        _ ->
          %% TODO revise __MODULE__ to be macro, which is expended during compilation.
          case Id of
            '__MODULE__' ->
              translate({atom, Meta, ?m(TCtx2, namespace)}, TCtx2);
            '__DIR__' ->
              Dir = kapok_utils:characters_to_binary(filename:dirname(?m(TCtx2, file))),
              translate({binary_string, Meta, Dir}, TCtx2);
            _ ->
              throw({unresolved_local_call, FunArity, Meta})
          end
      end
  end;
%%  Remote call
translate({list, Meta, [{dot, DotMeta, {Left, Right}} = Dot | Args]}, Ctx) ->
  case is_plain_dot(Dot) of
    true ->
      {Module, Fun} = plain_dot_mf(Dot),
      {TArgs, TCtx1} = translate_args(Args, Ctx),
      Arity = length(TArgs),
      case is_identifier(Left) of
        true ->
          case kapok_ctx:get_var(Meta, TCtx1, Module) of
            {ok, _} ->
              %% If module or fun part is a variable, there is no way to figure out the
              %% signature of the calling function by looking at its declaration or definition.
              %% So the signature MFAP is assumed to be `{Module, Fun, Arity, 'normal'}`
              %% as the best guess.
              FAst = case is_identifier(Right) of
                       true ->
                         case kapok_ctx:get_var(Meta, TCtx1, Fun) of
                           {ok, _} -> Right;
                           error -> {atom, token_meta(Right), Fun}
                         end;
                       false ->
                         {atom, token_meta(Right), Fun}
                     end,
              translate_remote_call(Meta, Left, FAst, Arity, 'normal', Arity, TArgs, TCtx1);
            error ->
              translate_module_call(Meta, DotMeta, Right, Module, Fun, TArgs, Arity, TCtx1)
          end;
        false ->
          translate_module_call(Meta, DotMeta, Right, Module, Fun, TArgs, Arity, TCtx1)
      end;
    false ->
      translate_dot_let(Meta, tuple_to_list(token_symbol(Dot)), Args, Ctx)
  end;
translate({list, Meta, [{list, _, _} = H | T]}, Ctx) ->
  {TH, TCtx1} = translate(H, Ctx),
  {TT, TCtx2} = translate(T, TCtx1),
  translate_local_call(Meta, TH, TT, TCtx2);
translate({list, Meta, [_H | _T]} = Ast, Ctx) ->
  kapok_error:compile_error(Meta, ?m(Ctx, file), "invalid function call ~s", [token_text(Ast)]);
translate({list, _Meta, []}, Ctx) ->
  translate_list([], Ctx);

%% Lisp Special Forms

%% quote
translate({quote, Meta, Arg}, Ctx) ->
  %% TODO add unquote/unquote_splicing backquote pair checking
  translate(quote(Meta, Arg), Ctx);

%% backquote
%% The backquote is pushed down into the collections(list, cons-list, map, etc.) elements.
%% and then translated. We don't simply use backquote_level/unquote_level in macro_context
%% to indicate backquote/unquote environment in order to avoid always checking
%% backquote_level/unquote_level in other translate clauses for translating other types.

%% backquote a quote expression
translate({backquote, _, {quote, Meta, Arg}}, Ctx) ->
  {TC, TCtx} = translate({atom, Meta, 'quote'}, Ctx),
  {TMeta, TCtx1} = translate(quote(Meta, Meta), TCtx),
  {TArg, TCtx2} = translate({backquote, Meta, Arg}, TCtx1),
  {build_tuple(Meta, [TC, TMeta, TArg]), TCtx2};
%% embedded backquote
translate({backquote, _, {backquote, Meta, Arg}}, #{macro_context := Context} = Ctx) ->
  B = ?m(Context, backquote_level),
  Context1 = Context#{backquote_level => B + 1},
  {TC, TCtx1} = translate({atom, Meta, 'backquote'}, Ctx#{macro_context => Context1}),
  {TMeta, TCtx2} = translate(quote(Meta, Meta), TCtx1),
  {TArg, TCtx3} = translate({backquote, Meta, Arg}, TCtx2),
  {build_tuple(Meta, [TC, TMeta, TArg]), TCtx3#{macro_context => Context}};
%% backquote an unquote expression
translate({backquote, _, {unquote, Meta, Arg}}, #{macro_context := Context} = Ctx) ->
  B = ?m(Context, backquote_level),
  U = ?m(Context, unquote_level),
  if
    U == B ->
      {EArg, ECtx} = eval(Arg, Ctx),
      translate(EArg, ECtx);
    U < B ->
      {TC, TCtx}= translate({atom, Meta, 'unquote'}, Ctx),
      {TMeta, TCtx1} = translate(quote(Meta, Meta), TCtx),
      Context1 = Context#{unquote_level => U + 1},
      {TArg, TCtx2} = translate({backquote, Meta, Arg}, TCtx1#{macro_context => Context1}),
      {build_tuple(Meta, [TC, TMeta, TArg]), TCtx2#{macro_context => Context}};
    U > B ->
      kapok_error:compile_error(Meta, ?m(Ctx, file), "unquote doesn't match backquote")
  end;
%% backquote an unquote_splicing expression
translate({backquote, _, {unquote_splicing, Meta, Arg}}, #{macro_context := Context} = Ctx) ->
  B = ?m(Context, backquote_level),
  U = ?m(Context, unquote_level),
  if
    U == B ->
      {EArg, ECtx} = eval(Arg, Ctx),
      {TArg, TCtx} = translate(EArg, ECtx),
      {{evaluated_unquote_splicing, Meta, TArg}, TCtx};
    U < B ->
      {TC, TCtx} = translate({atom, Meta, 'unquote_splicing'}, Ctx),
      {TMeta, TCtx1} = translate(quote(Meta, Meta), TCtx),
      Context1 = Context#{unquote_level => U + 1},
      {TArg, TCtx2} = translate({backquote, Meta, Arg}, TCtx1#{macro_context => Context1}),
      {build_tuple(Meta, [TC, TMeta, TArg]), TCtx2#{macro_context => Context}};
    U > B ->
      kapok_error:compile_error(Meta, ?m(Ctx, file), "unquote_splicing doesn't match backquote")
  end;
%% backquote a list
translate({backquote, _, {Category, _, _} = Arg}, Ctx) when ?is_list(Category) ->
  translate_backquote_list(Arg, Ctx);
%% backquote a cons list
translate({backquote, _, {Category, Meta, {Head, Tail}}}, Ctx) when ?is_cons_list(Category) ->
  {TC, TCtx} = translate({atom, Meta, Category}, Ctx),
  {TMeta, TCtx1} = translate(quote(Meta, Meta), TCtx),
  {THead, TCtx2} = lists:mapfoldl(fun (Ast, C) ->
                                      translate({backquote, token_meta(Ast), Ast}, C)
                                  end,
                                  TCtx1,
                                  Head),
  {TTail, TCtx3} = translate({backquote, token_meta(Tail), Tail}, TCtx2),
  {build_tuple(Meta, [TC, TMeta, build_tuple(Meta, [build_list(THead), TTail])]), TCtx3};
%% backquote a collection but not list
translate({backquote, _, {Category, Meta, Args}}, Ctx)
    when Category == 'bitstring', is_list(Args);
         Category == 'tuple';
         Category == 'map';
         Category == 'set' ->
  {TC, TCtx} = translate({atom, Meta, Category}, Ctx),
  {TMeta, TCtx1} = translate(quote(Meta, Meta), TCtx),
  {TArgs, TCtx2} = lists:mapfoldl(fun(Ast, C) ->
                                      translate({backquote, token_meta(Ast), Ast}, C)
                                  end,
                                  TCtx1,
                                  Args),
  {build_tuple(Meta, [TC, TMeta, build_list(TArgs)]), TCtx2};
translate({backquote, _, {Category, Meta, {Module, Fun}}}, Ctx) when ?is_dot(Category) ->
  {TC, TCtx} = translate({atom, Meta, Category}, Ctx),
  {TMeta, TCtx1} = translate(quote(Meta, Meta), TCtx),
  {TModule, TCtx2} = translate({backquote, token_meta(Module), Module}, TCtx1),
  {TFun, TCtx3} = translate({backquote, token_meta(Fun), Fun}, TCtx2),
  {build_tuple(Meta, [TC, TMeta, build_tuple(Meta, [TModule, TFun])]), TCtx3};
%% backquote a non-collection type, e.g. an atom.
translate({backquote, Meta, Arg}, Ctx) ->
  translate({quote, Meta, Arg}, Ctx);

%% standalone unquote and unquote_splicing
translate({Category, Meta, _}, Ctx) when Category == unquote; Category == unquote_splicing ->
  kapok_error:compile_error(Meta, ?m(Ctx, file), "~s outside backquote", [Category]);
translate({evaluated_unquote_splicing, Meta, _}, Ctx) ->
  kapok_error:compile_error(Meta, ?m(Ctx, file), "unquote_splicing outside a list");

%% standalone dot
translate({dot, Meta, _} = Dot, Ctx) ->
  kapok_error:compile_error(Meta, ?m(Ctx, file), "invalid dot: ~p", [Dot]);

%% bind
translate({bind, Meta, {Arg, Id}} = Bind, #{context := Context} = Ctx) ->
  case Context of
    C when C == fn_pattern; C == let_pattern; C == case_pattern ->
      {TArg, TCtx1} = translate(Arg, Ctx),
      {TId, TCtx2} = translate(Id, TCtx1),
      {{match, ?line(Meta), TArg, TId}, TCtx2};
    _ ->
      kapok_error:compile_error(Meta, ?m(Ctx, file), "invalid bind: ~p", [Bind])
  end;

%% errors for function argument keywords
translate({Category, Meta} = Token, Ctx) when ?is_parameter_keyword(Category) ->
  Error = {parameter_keyword_outside_fun_args, {Token}},
  kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, Error);

%% All other things
translate(Other, Ctx) ->
  {to_abstract_format(Other), Ctx}.


%% Helper Functions

to_var(Meta, Name) ->
  {var, ?line(Meta), Name}.

%% Converts specified code to erlang abstract format

to_abstract_format(Tree) when is_atom(Tree) ->
  {atom, 0, Tree};
to_abstract_format(Tree) when is_integer(Tree) ->
  {integer, 0, Tree};
to_abstract_format(Tree) when is_float(Tree) ->
  {float, 0, Tree};
to_abstract_format(<<>>) ->
  {bin, 0, []};
to_abstract_format(Tree) when is_binary(Tree) ->
  %% Note that our binaries are utf-8 encoded and we are converting
  %% to a list using binary_to_list. The reason for this is that Erlang
  %% considers a string in a binary to be encoded in latin1, so the bytes
  %% are not changed in any fashion.
  {bin, 0, [{bin_element, 0, {string, 0, binary_to_list(Tree)}, default, default}]};
to_abstract_format(Tree) when is_tuple(Tree) ->
  {tuple, 0, [to_abstract_format(X) || X <- tuple_to_list(Tree)]};
to_abstract_format([]) ->
  {nil, 0};
to_abstract_format(Tree) when is_list(Tree) ->
  to_abstract_format_cons_1(Tree, []);
to_abstract_format(Function) when is_function(Function) ->
  case (erlang:fun_info(Function, type) == {type, external}) andalso
    (erlang:fun_info(Function, env) == {env, []}) of
    true ->
      {module, Module} = erlang:fun_info(Function, module),
      {name, Name}     = erlang:fun_info(Function, name),
      {arity, Arity}   = erlang:fun_info(Function, arity),

      {'fun', 0, {function,
                  {atom, 0, Module},
                  {atom, 0, Name},
                  {integer, 0, Arity}}};
    false ->
      error(badarg)
  end;

to_abstract_format(Pid) when is_pid(Pid) ->
  abstract_format_remote_call(0, erlang, binary_to_term, [to_abstract_format(term_to_binary(Pid))]);
to_abstract_format(_Other) ->
  error(badarg).

to_abstract_format_cons_1([H|T], Acc) ->
  to_abstract_format_cons_1(T, [H|Acc]);
to_abstract_format_cons_1(Other, Acc) ->
  to_abstract_format_cons_2(Acc, to_abstract_format(Other)).

to_abstract_format_cons_2([H|T], Acc) ->
  to_abstract_format_cons_2(T, {cons, 0, to_abstract_format(H), Acc});
to_abstract_format_cons_2([], Acc) ->
  Acc.

abstract_format_remote_call(Line, Module, Function, Args) ->
  {call, Line, {remote, Line, {atom, Line, Module}, {atom, Line, Function}}, Args}.


%% Macro Evaluation

%% TODO refactor the eval ast process
eval({list, Meta, [{identifier, IdMeta, Id} | Args]} = Ast, Ctx) ->
  Arity = length(Args),
  {R, Ctx1} = kapok_dispatch:find_local_macro(Meta, {Id, Arity}, IdMeta, Args, Ctx),
  case R of
    {Tag, _} when Tag == local; Tag == remote ->
      kapok_compiler:eval_ast(Ast, kapok_ctx:reset_macro_context(Ctx1));
    {rewrite, Ast1} ->
      kapok_compiler:eval_ast(Ast1, kapok_ctx:reset_macro_context(Ctx1));
    false ->
      %% TODO expand eval ast indeed
      {Ast, Ctx1}
  end;
eval({list, Meta, [{dot, _, {Module, Fun}} | Args]} = Ast, Ctx) ->
  Arity = length(Args),
  {R, Ctx1} = kapok_dispatch:find_remote_macro(Meta, Module, {Fun, Arity}, Ctx),
  case R of
    {remote, _} ->
      kapok_compiler:eval_ast(Ast, kapok_ctx:reset_macro_context(Ctx1));
    {rewrite, Ast1} ->
      kapok_compiler:eval_ast(Ast1, kapok_ctx:reset_macro_context(Ctx1));
    false ->
      {Ast, Ctx1}
  end;
eval(Ast, Ctx) ->
  {Ast, Ctx}.

%% Quotes.

%% atom
quote(Meta, Atom) when is_atom(Atom) ->
  {atom, Meta, Atom};
%% number
quote(Meta, Number) when is_number(Number) ->
  {number, Meta, Number};
%% list string and binary string
quote(Meta, Binary) when is_binary(Binary) ->
  {bitstring, Meta, {binary_string, Meta, Binary}};
%% tuple
quote(Meta, Tuple) when is_tuple(Tuple) ->
  {tuple, Meta, lists:map(fun(X) -> quote(Meta, X) end, tuple_to_list(Tuple))};
%% list
quote(Meta, List) when is_list(List) ->
  {literal_list, Meta, lists:map(fun(X) -> quote(Meta, X) end, List)};
%% map
quote(Meta, Map) when is_map(Map) ->
  {map, Meta, lists:reverse(lists:foldl(fun({K, V}, Acc) ->
                                            [quote(Meta, V), quote(Meta, K) | Acc]
                                        end,
                                        [],
                                        maps:to_list(Map)))}.

%% translate backquote list
translate_backquote_list({Category, Meta, List}, Ctx) ->
  {TL, TCtx} = lists:mapfoldl(fun(Ast, Ctx1) ->
                                  translate({backquote, token_meta(Ast), Ast}, Ctx1)
                              end,
                              Ctx,
                              List),
  translate_backquote_list(Category, Meta, lists:reverse(TL), [], [], TCtx).
translate_backquote_list(_Category, _Meta, [], [], Acc, Ctx) when is_tuple(Acc) ->
  {Acc, Ctx};
translate_backquote_list(Category, Meta, [], [], Acc, Ctx) when is_list(Acc) ->
  {TC, TCtx1} = translate({atom, Meta, Category}, Ctx),
  {TMeta, TCtx2} = translate(quote(Meta, Meta), TCtx1),
  TAst = build_tuple(Meta, [TC, TMeta, build_list(Acc)]),
  {TAst, TCtx2};
translate_backquote_list(Category, Meta, [], Atoms, Acc, Ctx) when is_tuple(Acc) ->
  'build_macro_list*'(Category, Meta, Atoms, Acc, Ctx);
translate_backquote_list(Category, Meta, [], Atoms, Acc, Ctx) when is_list(Acc) ->
  translate_backquote_list(Category, Meta, [], [], lists:append(Atoms, Acc), Ctx);
translate_backquote_list(Category, Meta, [{evaluated_unquote_splicing, Meta1, Arg}|T], Atoms, Acc, Ctx) ->
  {TAst, TCtx} = translate_backquote_list(Category, Meta, [], Atoms, Acc, Ctx),
  {TAst1, TCtx1} = build_macro_append(Meta1, Arg, TAst, TCtx),
  translate_backquote_list(Category, Meta, T, [], TAst1, TCtx1);
translate_backquote_list(Category, Meta, [H|T], Atoms, Acc, Ctx) ->
  translate_backquote_list(Category, Meta, T, [H|Atoms], Acc, Ctx).

'build_macro_list*'(Category, Meta, Atoms, Tail, Ctx) when is_tuple(Tail) ->
  {TC, TCtx} = translate({atom, Meta, Category}, Ctx),
  {TMeta, TCtx1} = translate(quote(Meta, Meta), TCtx),
  {TListC, TCtx2} = translate({atom, Meta, 'list'}, TCtx1),
  {TDotC, TCtx3} = translate({atom, Meta, 'dot'}, TCtx2),
  {TM, TCtx4} = translate({atom, Meta, 'kapok_macro'}, TCtx3),
  {TF, TCtx5} = translate({atom, Meta, 'list*'}, TCtx4),
  {TIdentifierC, TCtx6} = translate({atom, Meta, 'identifier'}, TCtx5),
  TModule = build_tuple(Meta, [TIdentifierC, TMeta, TM]),
  TFun = build_tuple(Meta, [TIdentifierC, TMeta, TF]),
  TListDot = build_tuple(Meta, [TDotC, TMeta, build_tuple(Meta, [TModule, TFun])]),
  TAtoms = build_tuple(Meta, [TC, TMeta, build_list(Atoms)]),
  TAst = build_tuple(Meta, [TListC, TMeta, build_list([TListDot, TAtoms, Tail])]),
  {TAst, TCtx6}.

build_macro_append(Meta, THead, Tail, Ctx) ->
  {TListC, TCtx} = translate({atom, Meta, 'list'}, Ctx),
  {TMeta, TCtx1} = translate(quote(Meta, Meta), TCtx),
  {TDotC, TCtx2} = translate({atom, Meta, 'dot'}, TCtx1),
  {TM, TCtx3} = translate({atom, Meta, 'kapok_macro'}, TCtx2),
  {TF, TCtx4} = translate({atom, Meta, 'append'}, TCtx3),
  {TIdentifierC, TCtx5} = translate({atom, Meta, 'identifier'}, TCtx4),
  TModule = build_tuple(Meta, [TIdentifierC, TMeta, TM]),
  TFun = build_tuple(Meta, [TIdentifierC, TMeta, TF]),
  TAppend = build_tuple(Meta, [TDotC, TMeta, build_tuple(Meta, [TModule, TFun])]),
  TAst = build_tuple(Meta, [TListC, TMeta, build_list([TAppend, THead, Tail])]),
  {TAst, TCtx5}.

%% fn remote reference
translate_remote_fn(Meta,
                    {C1, Meta1, Module} = MAst,
                    {_, Meta2, Fun} = FunAst,
                    {_, _, _} = ArityAst,
                    Ctx) ->
  case is_identifier(FunAst) of
    true ->
      case kapok_ctx:get_var(Meta2, Ctx, Fun) of
        {ok, _} ->
          Original = kapok_dispatch:find_module(Meta, Module, Ctx),
          MAst1 = {C1, Meta1, Original},
          translate_fn(Meta, MAst1, FunAst, ArityAst, Ctx);
         error ->
          translate_static_remote_fn(Meta, MAst, FunAst, ArityAst, Ctx)
      end;
    false ->
      translate_static_remote_fn(Meta, MAst, FunAst, ArityAst, Ctx)
  end.

translate_static_remote_fn(Meta,
                           {_, Meta1, Module},
                           {_, Meta2, Fun},
                           {_, _, Arity} = ArityAst,
                           Ctx) ->
  FunArity = {Fun, Arity},
  Namespace = ?m(Ctx, namespace),
  case Module of
    Namespace ->
      case kapok_dispatch:find_local_function(FunArity, Ctx) of
        {F, Arity, _P} ->
          MAst = {atom, Meta1, Module},
          FAst = {atom, Meta2, F},
          translate_fn(Meta, MAst, FAst, ArityAst, Ctx);
        _ ->
          throw({unresolved_local_call, FunArity, Meta})
      end;
    _ ->
      case kapok_dispatch:find_remote_function(Meta, Module, FunArity, Ctx) of
        {{M, F, Arity, _P}, Ctx1} ->
          MAst = {atom, Meta1, M},
          FAst = {atom, Meta2, F},
          translate_fn(Meta, MAst, FAst, ArityAst, Ctx1);
        _ ->
          kapok_error:compile_error(Meta, ?m(Ctx, file),
                                    "invalid fn remote reference: (fn ~p ~p ~p)",
                                    [Module, Fun, Arity])
      end
  end.

%% local call
translate_local_call(Meta, F, A, P, Arity, TArgs, Ctx) ->
  {TF, TCtx} = translate(F, Ctx),
  TArgs1 = construct_new_args('translate', Arity, A, P, TArgs),
  translate_local_call(Meta, TF, TArgs1, TCtx).
translate_local_call(Meta, TF, TArgs, Ctx) ->
  {{call, ?line(Meta), TF, TArgs}, Ctx}.

%% remote call
translate_module_call(Meta, DotMeta, Right, Module, Fun, TArgs, Arity, Ctx) ->
  case is_identifier(Right) of
    true ->
      case kapok_ctx:get_var(Meta, Ctx, Fun) of
        {ok, _} ->
          %% If module or fun part is a variable, there is no way to figure out the
          %% signature of the calling function by looking at its declaration or definition.
          %% So the signature MFAP is assumed to be `{Module, Fun, Arity, 'normal'}`
          %% as the best guess.
          MAst = {atom, DotMeta, Module},
          FAst = Right,
          translate_remote_call(Meta, MAst, FAst, Arity, 'normal', Arity, TArgs, Ctx);
        error ->
          translate_static_remote_call(Meta, DotMeta, Module, Fun, TArgs, Arity, Ctx)
      end;
    false ->
      translate_static_remote_call(Meta, DotMeta, Module, Fun, TArgs, Arity, Ctx)
  end.

translate_static_remote_call(Meta, DotMeta, Module, Fun, TArgs, Arity, Ctx) ->
  FunArity = {Fun, Arity},
  Namespace = ?m(Ctx, namespace),
  case Module of
    Namespace ->
      %% call to local module
      case kapok_dispatch:find_local_function(FunArity, Ctx) of
        {F, A, P} ->
          MAst = {atom, DotMeta, Module},
          FAst = {atom, DotMeta, F},
          translate_remote_call(Meta, MAst, FAst, A, P, Arity, TArgs, Ctx);
        _ ->
          throw({unresolved_local_call, FunArity, Meta})
      end;
    _ ->
      case kapok_dispatch:find_remote_function(Meta, Module, FunArity, Ctx) of
        {{M, F, A, P}, Ctx1} ->
          MAst = {atom, DotMeta, M},
          FAst = {atom, DotMeta, F},
          translate_remote_call(Meta, MAst, FAst, A, P, Arity, TArgs, Ctx1);
        {false, Ctx1} ->
          kapok_error:compile_error(Meta, ?m(Ctx1, file),
                                    "invalid remote call: ~p ~p", [Module, FunArity])
      end
  end.

translate_remote_call(Meta, M, F, A, P, Arity, TArgs, Ctx) ->
  TArgs1 = construct_new_args('translate', Arity, A, P, TArgs),
  translate_remote_call(Meta, M, F, TArgs1, Ctx).
translate_remote_call(Meta, M, F, TArgs, Ctx) ->
  {TM, TCtx} = translate(M, Ctx),
  {TF, TCtx1} = translate(F, TCtx),
  Line = ?line(Meta),
  {{call, Line, {remote, Line, TM, TF}, TArgs}, TCtx1}.

construct_new_args(Context, Arity, NewArity, ParaType, Args) ->
  case (ParaType == rest) andalso (Arity >= NewArity) of
    true ->
      {NormalParas, RestPara} = lists:split(NewArity-1, Args),
      case Context of
        'expand' -> NormalParas ++ [RestPara];
        'translate' -> NormalParas ++ [build_list(RestPara)]
      end;
    false ->
      Args
  end.

map_vars(Meta, TMapArg, TKeyParameters, Ctx) ->
  {TM, TCtx} = translate({atom, Meta, 'maps'}, Ctx),
  {TF, TCtx1} = translate({atom, Meta, 'get'}, TCtx),
  Line = ?line(Meta),
  L = lists:foldl(fun({TId, TDefault}, Acc) ->
                      Call = {call, Line, {remote, Line, TM, TF},
                              [var_to_keyword(TId), TMapArg, TDefault]},
                      C = {match, ?line(Meta), TId, Call},
                      [C | Acc]
                  end,
                  [],
                  TKeyParameters),
  {lists:reverse(L), TCtx1}.

var_to_keyword({var, Line, Id}) ->
  {atom, Line, Id}.

%% arguments

translate_def_arg(Arg, #{context := Context} = Ctx) ->
  {TArg, TCtx} = translate(Arg, Ctx#{context => fn_pattern}),
  {TArg, TCtx#{context => Context}}.

translate_def_args({literal_list, _, Args}, Ctx) ->
  lists:mapfoldl(fun translate_def_arg/2, Ctx, Args);
translate_def_args(Args, Ctx) when is_list(Args) ->
  lists:mapfoldl(fun translate_def_arg/2, Ctx, Args).

translate_arg(Arg, Ctx) ->
  translate(Arg, Ctx).

translate_args({Category, _, Args}, Ctx) when ?is_list(Category) ->
  translate_args(Args, Ctx);
translate_args(Args, Ctx) when is_list(Args) ->
  {L, TCtx} = translate_args(Args, {[], []}, {normal, [], []}, Ctx),
  case lists:reverse(L) of
    [{normal, _, TNormalArgs}] ->
      {TNormalArgs, TCtx};
    [{normal, _, TNormalArgs}, {keyword, Meta, Pairs}] ->
      MapArg = build_map_from(Meta, Pairs),
      {TNormalArgs ++ [MapArg], TCtx}
  end.

translate_args([], {_Keys, Acc}, {Previous, Meta, Args}, Ctx) ->
  {[{Previous, Meta, lists:reverse(Args)} | Acc], Ctx};

translate_args([{keyword, Meta, Value} = Token], _, {keyword, _, _}, Ctx)
    when Value == true; Value == false; Value == nil ->
  kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, {invalid_key, {Token}});
translate_args([{keyword, _, Value} = Token | T], Acc, {normal, Meta1, Args}, Ctx)
    when Value == true; Value == false; Value == nil ->
  {TH, TCtx} = translate_arg(Token, Ctx),
  translate_args(T, Acc, {normal, Meta1, [TH | Args]}, TCtx);
translate_args([{keyword, Meta, _} = Token], _, {_Previous, _Meta, _Args}, Ctx) ->
  kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, {dangling_keyword, {Token}});
translate_args([{keyword, Meta, Atom} = Keyword, Expr | T], {Keys, Acc}, {normal, Meta1, Args},
               Ctx) ->
  case ordsets:is_element(Atom, Keys) of
    true -> kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, {duplicate_keyword, {Keyword}});
    false -> ok
  end,
  {TKeyword, TCtx} = translate_arg(Keyword, Ctx),
  {TExpr, TCtx1} = translate_arg(Expr, TCtx),
  Keys1 = ordsets:add_element(Atom, Keys),
  Acc1 = [{normal, Meta1, lists:reverse(Args)} | Acc],
  translate_args(T, {Keys1, Acc1}, {keyword, Meta, [{TKeyword, TExpr}]}, TCtx1);
translate_args([{keyword, Meta, Value} = Token, _Expr | _T], _, {keyword, _, _}, Ctx)
    when Value == true; Value == false; Value == nil ->
  kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, {invalid_key, {Token}});
translate_args([{keyword, Meta, Atom} = Keyword, Expr | T], {Keys, Acc}, {keyword, Meta1, Args},
               Ctx) ->
  case ordsets:is_element(Atom, Keys) of
    true -> kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, {duplicate_keyword, {Keyword}});
    false -> ok
  end,
  {TKeyword, TCtx} = translate_arg(Keyword, Ctx),
  {TExpr, TCtx1} = translate_arg(Expr, TCtx),
  Keys1 = ordsets:add_element(Atom, Keys),
  translate_args(T, {Keys1, Acc}, {keyword, Meta1, [{TKeyword, TExpr} | Args]}, TCtx1);
translate_args([H | T], Acc, {normal, Meta1, Args}, Ctx) ->
  {TH, TCtx} = translate_arg(H, Ctx),
  translate_args(T, Acc, {normal, Meta1, [TH | Args]}, TCtx);
translate_args([H | _T], _, {keyword, _Meta1, _Args}, Ctx) ->
  kapok_error:form_error(token_meta(H), ?m(Ctx, file), ?MODULE, {missing_key_for_argument, {H}}).

%% guard
translate_guard([], Ctx) ->
  {[], Ctx};
translate_guard({list, Meta, [{keyword_when, _, _} | Body]}, Ctx) ->
  case Body of
    [] ->
      Error = {missing_guard},
      kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, Error);
    [H] ->
      translate_guard(H, nil, Ctx);
    [H | T] ->
      Error = {too_many_guards, {H, T}},
      kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, Error)
  end.
translate_guard({list, Meta, [{keyword_and, _, _} | Left]}, 'and', Ctx) ->
  Error = {invalid_nested_and_or_in_guard, {'and', 'and', Left}},
  kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, Error);
translate_guard({list, Meta, [{keyword_and, _, _} | Left]}, Parent, Ctx) ->
  case Left of
    [E1, E2 | Tail] ->
      {TE1, TCtx} = translate_guard(E1, 'and', Ctx),
      {TE2, TCtx1} = translate_guard(E2, 'and', TCtx),
      {TLeft, TCtx2} = lists:mapfoldl(fun (X, C) -> translate_guard(X, 'and', C) end,
                                      TCtx1,
                                      Tail),
      L = [TE1, TE2 | TLeft],
      case Parent of
        nil -> {[L], TCtx2};
        'or' -> {L, TCtx2}
      end;
    [Tail] ->
      Error1 = {not_enough_operand_in_guard, {'and', Tail}},
      kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, Error1)
  end;
translate_guard({list, _, [{keyword_or, _, _} | Left]}, nil, Ctx) ->
  lists:mapfoldl(fun (X, E) -> translate_guard(X, 'or', E) end, Ctx, Left);
translate_guard({list, Meta, [{keyword_or, _, _} | Left]}, Parent, Ctx) ->
  Error = {invalid_nested_and_or_in_guard, {Parent, 'or', Left}},
  kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, Error);
translate_guard(Other, nil, Ctx) ->
  {TOther, TCtx} = translate(Other, Ctx),
  %% as only expression in 'or'
  {[[TOther]], TCtx};
translate_guard(Other, 'or', Ctx) ->
  {TOther, TCtx} = translate(Other, Ctx),
  %% actually one expression in 'or'
  {[TOther], TCtx};
translate_guard(Other, _Parent, Ctx) ->
  translate(Other, Ctx).

%% body
translate_body(Meta, Body, Ctx) ->
  case Body of
    [] ->
      kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, {missing_body});
    _ ->
      translate(Body, Ctx)
  end.

%% logical operators
op_type('op-not') -> 'not';
op_type('op-and') -> 'and';
op_type('op-or') -> 'or';
op_type('op-xor') -> 'xor';
op_type('op-andalso') -> 'andalso';
op_type('op-orelse') -> 'orelse';
%% list operators
op_type('op-++') -> '++'.

%% Error

format_error({invalid_fn_local_imported, {{Id, Number}, MFAP}}) ->
  io_lib:format("invalid fn (~p ~p) refer to remote function call: ~p", [Id, Number, MFAP]);
format_error({invalid_fn_local_var, {Id}}) ->
  io_lib:format("invalid var ~p used in fn form", [Id]);
format_error({parameter_keyword_outside_fun_args, {Token}}) ->
  io_lib:format("invalid ~s outside the arguments of a function definition", [token_text(Token)]);
format_error({missing_body}) ->
  io_lib:format("body is missing", []);
format_error({invalid_key, {Token}}) ->
  io_lib:format("invalid key ~s", [token_text(Token)]);
format_error({dangling_keyword, {Token}}) ->
  io_lib:format("dangling ~s without argument", [token_text(Token)]);
format_error({duplicate_keyword, {Token}}) ->
  io_lib:format("duplicate keyword ~s", [token_text(Token)]);
format_error({missing_key_for_argument, {Token}}) ->
  io_lib:format("missing key for argument ~s", [token_text(Token)]);
format_error({missing_guard}) ->
  io_lib:format("case clause guard is missing");
format_error({too_many_guards, {First, Left}}) ->
  io_lib:format("too many arguments for when, please use and/or for "
                "guard tests or sequences: ~w, ~w",
                [First, Left]);
format_error({invalid_nested_and_or_in_guard, {Parent, Id, Left}}) ->
  io_lib:format("invalid nested and/or in guard, parent: ~p, current: ~p, args: ~w",
                [Parent, Id, Left]);
format_error({not_enough_operand_in_guard, {Op, Operand}}) ->
  io_lib:format("not enough operand for ~p, given: ~w", [Op, Operand]).

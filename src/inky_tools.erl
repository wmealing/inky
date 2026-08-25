-module(inky_tools).

-export([all/0, relevant_schemas/1, dispatch/2, interpret/1]).

%% Auto-discovers tool modules: any module belonging to the inky
%% application whose `-behaviour(inky_tool)` attribute is set. Adding a
%% new tool is just adding such a module -- nothing here needs editing.
all() ->
    {ok, Modules} = application:get_key(inky, modules),
    lists:filter(fun is_tool_module/1, Modules).

is_tool_module(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            Attrs = Module:module_info(attributes),
            Behaviours = lists:flatten(proplists:get_all_values(behaviour, Attrs)),
            lists:member(inky_tool, Behaviours);
        _ ->
            false
    end.

%% Schemas for tools whose keywords match the latest user message --
%% only these are advertised to the model for this request.
relevant_schemas(Messages) ->
    case last_user_content(Messages) of
        undefined -> [];
        Content ->
            Lower = iolist_to_binary(string:lowercase(Content)),
            [Module:schema() || Module <- all(), Module:matches(Lower)]
    end.

last_user_content(Messages) ->
    case lists:filter(fun(#{<<"role">> := R}) -> R =:= <<"user">> end, Messages) of
        [] -> undefined;
        Users -> maps:get(<<"content">>, lists:last(Users), undefined)
    end.

%% Whether the named tool wants its result re-interpreted by the model
%% before the user sees it. Unknown or silent tools default to false, so
%% the verbatim path stays the default for everything that doesn't opt in.
interpret(Name) ->
    case lookup(Name) of
        {ok, Module} ->
            erlang:function_exported(Module, interpret, 0) andalso Module:interpret();
        error ->
            false
    end.

dispatch(Name, Args) ->
    case lookup(Name) of
        {ok, Module} -> Module:dispatch(Args);
        error -> iolist_to_binary(io_lib:format("Unknown tool: ~s", [Name]))
    end.

lookup(Name) ->
    case lists:filter(fun(M) -> M:name() =:= Name end, all()) of
        [Module | _] -> {ok, Module};
        [] -> error
    end.

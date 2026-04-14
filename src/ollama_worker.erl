-module(ollama_worker).
-behaviour(gen_server).

-export([start_link/0, ask/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-record(state, {
    model = <<"llama3.2:latest">>,
    url = <<"http://localhost:11434/api/chat">>,
    history = []
}).

%% --- API ---
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

ask(Question) ->
    Content = gen_server:call(?MODULE, {ask, Question}, 30000),
    maps:get(<<"content">>, Content).

%% --- Callbacks ---
init([]) ->
    {ok, #state{}}.

handle_call({ask, Question}, _From, State) ->
    UserMsg = #{<<"role">> => <<"user">>, <<"content">> => Question},
    NewHistory = State#state.history ++ [UserMsg],

    %% Recursive tool handling logic
    case process_interaction(NewHistory, State) of
        {ok, FinalMsg, UpdatedHistory} ->
            {reply, FinalMsg, State#state{history = UpdatedHistory}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

%% --- Interaction Logic ---
process_interaction(Messages, State) ->
    io:format("process-interaction"),
    case call_ollama(Messages, State) of
        {tool_call, ToolCalls, AssistantMsg} ->
            %% 1. Execute the Erlang tools
            ToolResults = execute_tools(ToolCalls),
            %% 2. Append the assistant's request and our tool results to history
            NextHistory = Messages ++ [AssistantMsg | ToolResults],
            %% 3. Recursively call Ollama to let it "see" the tool output
            process_interaction(NextHistory, State);
        {content, AssistantMsg} ->
            {ok, AssistantMsg, Messages ++ [AssistantMsg]}
    end.

call_ollama(Messages, State) ->
    Payload = #{
        <<"model">> => State#state.model,
        <<"messages">> => Messages,
        <<"stream">> => false,
        <<"tools">> => [weather_tool_schema()]
    },

    JsonPayload = json:encode(Payload),

    %% We use {with_body, true} to get the body in the response tuple directly
    Options = [{with_body, true}, {pool, default}],

    case hackney:request(post, State#state.url, [], JsonPayload, Options) of
        {ok, 200, _Headers, Body} ->
            io:format("JSON: ~p~n", [Body]),
            MsgData = decode_json(Body),
            Msg = maps:get(<<"message">>, MsgData),

            case maps:get(<<"tool_calls">>, Msg, undefined) of
                undefined -> {content, Msg};
                Calls -> {tool_call, Calls, Msg}
            end;
        {error, Reason} ->
            exit({ollama_connection_failed, Reason})
    end.


decode_json(Binary) ->
    json:decode(Binary).

execute_tools(Calls) ->
    lists:map(fun(#{<<"function">> := Fn}) ->
        Name = maps:get(<<"name">>, Fn),
        %% Note: Some models send 'arguments' as a nested JSON string
        Args = case maps:get(<<"arguments">>, Fn) of
            B when is_binary(B) -> decode_json(B);
            M when is_map(M) -> M
        end,

        Result = dispatch_local_tool(Name, Args),
        #{<<"role">> => <<"tool">>, <<"content">> => Result}
    end, Calls).

dispatch_local_tool(<<"get_weather">>, #{<<"city">> := Loc}) ->
    <<"The weather in Brisbane is 22C.">>;

dispatch_local_tool(<<"get_weather">>, #{<<"city_name">> := Loc}) ->
    <<"The weather in Brisbane is 22C.">>;

dispatch_local_tool(<<"get_weather">>, #{<<"location">> := Loc}) ->
    <<"The weather in Brisbane is 22C.">>.

weather_tool_schema() ->
    #{<<"type">> => <<"function">>,
      <<"function">> => #{
        <<"name">> => <<"get_weather">>,
        <<"description">> => <<"Get current weather for a city">>,
        <<"parameters">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"location">> => #{<<"type">> => <<"string">>}
            }
        }
      }}.

handle_cast(_Msg, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.

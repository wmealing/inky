-module(ollama_worker).
-behaviour(gen_server).

-export([start_link/1, ask/2]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-record(state, {
    model = <<"qwen2.5:7b">>,
    url = <<"http://localhost:11434/api/chat">>,
    history = [],
    bot_name
}).

%% --- API ---
start_link(BotName) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [BotName], []).

ask(ChatId, Question) ->
    gen_server:call(?MODULE, {ask, ChatId, Question}, 300000).

%% --- Callbacks ---
init([BotName]) ->
    %% The identity line is load-bearing: with nothing asserting who it is,
    %% the model answers "who made you?" from whatever is most likely in its
    %% weights, and qwen2.5:7b reliably claims it was developed by Anthropic
    %% (phi3.5 claims Microsoft-via-OpenAI). Nothing in inky talks to any of
    %% them -- it's trained-in confabulation, and the system prompt is the
    %% only place it can be overridden.
    SystemMsg = #{<<"role">> => <<"system">>,
                  <<"content">> => <<"You are inky, a Telegram bot running on Wade's "
                                     "machine, backed by a local Ollama model. If asked "
                                     "what you are, say that. Never claim to be made by "
                                     "Anthropic, OpenAI, or Microsoft.\n"
                                     "You may be offered tools for this message. Only call "
                                     "a tool when the user's request clearly needs it. For "
                                     "every other question, answer directly yourself "
                                     "without calling any tool.">>},
    {ok, #state{bot_name = BotName, history = [SystemMsg]}}.

handle_call({ask, ChatId, Question}, _From, State) ->
    UserMsg = #{<<"role">> => <<"user">>, <<"content">> => Question},
    NewHistory = State#state.history ++ [UserMsg],
    case process_interaction(ChatId, NewHistory, State) of
        {ok, UpdatedHistory} ->
            {reply, ok, State#state{history = UpdatedHistory}};
        {error, Reason} ->
            ErrText = iolist_to_binary(io_lib:format("Ollama error: ~p", [Reason])),
            send_chunk(State#state.bot_name, ChatId, ErrText),
            {reply, ok, State}
    end.

%% --- Interaction logic ---
%% Streams a response; if the model asks for a tool call, run it locally.
%% What happens to the result then depends on the tool: most send their
%% output to the user verbatim, because it is already exact and must not
%% be paraphrased. Tools whose inky_tool:interpret/0 returns true (today,
%% sensor_tool) get a second round-trip through the model so their dense
%% columns of numbers arrive as a sentence.
process_interaction(ChatId, Messages, State) ->
    case stream_ollama(ChatId, Messages, State, offer_tools) of
        {tool_call, ToolCalls, AssistantMsg} ->
            ToolResults = execute_tools(ToolCalls),
            case wants_interpretation(ToolCalls) of
                true ->
                    interpret_result(ChatId, Messages, AssistantMsg, ToolResults, State);
                false ->
                    send_verbatim(ChatId, Messages, ToolResults, State)
            end;
        {ok, FullText} ->
            AssistantMsg = #{<<"role">> => <<"assistant">>, <<"content">> => FullText},
            {ok, Messages ++ [AssistantMsg]};
        {error, Reason} ->
            {error, Reason}
    end.

send_verbatim(ChatId, Messages, ToolResults, State) ->
    ResultText = tool_results_text(ToolResults),
    send_chunk(State#state.bot_name, ChatId, ResultText),
    %% Persist only the plain user/assistant exchange, not the raw
    %% tool_calls/tool-role messages: keeping those in history primes the
    %% model to re-invoke the tool on later, unrelated messages (it
    %% few-shots off its own prior tool_calls turn).
    FinalAssistantMsg = #{<<"role">> => <<"assistant">>, <<"content">> => ResultText},
    {ok, Messages ++ [FinalAssistantMsg]}.

wants_interpretation(Calls) ->
    lists:any(fun(#{<<"function">> := Fn}) ->
                  inky_tools:interpret(maps:get(<<"name">>, Fn))
              end, Calls).

%% Feed the tool output back for a second pass, streamed to the user as
%% prose. Two things matter here:
%%
%%  - Tools are NOT offered on this call. Handing the model the same tool
%%    list again while it is looking at that tool's output invites it to
%%    call it a second time, and there is no depth limit to catch that.
%%  - If the second pass comes back empty (or somehow still wants a tool),
%%    fall back to sending the raw reading. A wrong-looking answer beats a
%%    bot that silently says nothing.
%%
%% As with the verbatim path, only the final prose is kept in history --
%% the tool_calls and tool-role messages are used for this request and
%% then dropped.
interpret_result(ChatId, Messages, AssistantMsg, ToolResults, State) ->
    FollowUp = Messages ++ [AssistantMsg] ++ ToolResults ++ [interpret_instruction()],
    case stream_ollama(ChatId, FollowUp, State, no_tools) of
        {ok, FullText} ->
            case string:trim(FullText) of
                <<>> ->
                    io:format("OLLAMA: interpretation came back empty, sending raw~n"),
                    send_verbatim(ChatId, Messages, ToolResults, State);
                Trimmed ->
                    {ok, Messages ++ [#{<<"role">> => <<"assistant">>,
                                        <<"content">> => Trimmed}]}
            end;
        {tool_call, _Calls, _Msg} ->
            io:format("OLLAMA: interpretation asked for another tool, sending raw~n"),
            send_verbatim(ChatId, Messages, ToolResults, State);
        {error, Reason} ->
            io:format("OLLAMA: interpretation failed (~p), sending raw~n", [Reason]),
            send_verbatim(ChatId, Messages, ToolResults, State)
    end.

%% Small models will happily round, re-unit or invent numbers when asked to
%% "summarise" -- hence the blunt instruction to quote figures as given.
interpret_instruction() ->
    #{<<"role">> => <<"system">>,
      <<"content">> => <<"The tool output above is a live reading taken just now "
                         "from this machine. Relay it to the user in plain language, "
                         "in two or three short sentences. Quote the figures exactly "
                         "as they appear -- never invent, rescale or round a number "
                         "that is not there. Point out anything that looks unhealthy; "
                         "if it all looks normal, say so briefly.">>}.

tool_results_text(ToolResults) ->
    Texts = [Content || #{<<"content">> := Content} <- ToolResults],
    iolist_to_binary(lists:join(<<" ">>, Texts)).

%% --- Streaming logic ---
%% Ollama's /api/chat with "stream":true returns newline-delimited JSON
%% objects, one per token/fragment. We buffer fragments until we see a
%% paragraph break ("\n\n") and push each completed paragraph to Telegram
%% immediately, instead of waiting for the whole response. If the model
%% requests a tool call, its arguments arrive complete in one chunk
%% (usually the last), so we just watch for a "tool_calls" field.
stream_ollama(ChatId, Messages, State, ToolMode) ->
    BasePayload = #{
        <<"model">> => State#state.model,
        <<"messages">> => Messages,
        <<"stream">> => true
    },
    %% Only advertise tools whose keywords match the latest user message:
    %% offering a tool on every request tempts small models into calling
    %% it (or leaking tool-call-shaped JSON) on unrelated questions.
    %% no_tools suppresses them entirely, for the interpretation pass.
    Schemas = case ToolMode of
        no_tools -> [];
        offer_tools -> inky_tools:relevant_schemas(Messages)
    end,
    Payload = case Schemas of
        [] -> BasePayload;
        _ -> BasePayload#{<<"tools">> => Schemas}
    end,
    JsonPayload = json:encode(Payload),
    Options = [async, {recv_timeout, 280000}],
    case hackney:request(post, State#state.url, [], JsonPayload, Options) of
        {ok, ClientRef} ->
            stream_loop(ClientRef, ChatId, State#state.bot_name, undefined, <<>>, <<>>, <<>>, undefined);
        {error, Reason} ->
            {error, {ollama_connection_failed, Reason}}
    end.

stream_loop(ClientRef, ChatId, BotName, Status, LineBuf, ParaBuf, FullText, ToolAcc) ->
    receive
        {hackney_response, ClientRef, {status, StatusInt, _Reason}} ->
            stream_loop(ClientRef, ChatId, BotName, StatusInt, LineBuf, ParaBuf, FullText, ToolAcc);
        {hackney_response, ClientRef, {headers, _Headers}} ->
            stream_loop(ClientRef, ChatId, BotName, Status, LineBuf, ParaBuf, FullText, ToolAcc);
        {hackney_response, ClientRef, done} ->
            case Status of
                200 ->
                    case ToolAcc of
                        undefined ->
                            Trimmed = string:trim(ParaBuf),
                            case Trimmed of
                                <<>> -> ok;
                                _ -> send_chunk(BotName, ChatId, Trimmed)
                            end,
                            {ok, FullText};
                        {Calls, AssistantMsg} ->
                            {tool_call, Calls, AssistantMsg}
                    end;
                _ ->
                    {error, {ollama_http_error, Status, ParaBuf}}
            end;
        {hackney_response, ClientRef, Bin} when is_binary(Bin) ->
            case Status of
                200 ->
                    Combined = <<LineBuf/binary, Bin/binary>>,
                    {Lines, Rest} = split_lines(Combined),
                    {NewParaBuf, NewFullText, NewToolAcc} = lists:foldl(
                        fun(Line, {AccPara, AccFull, AccTool}) ->
                            handle_line(Line, BotName, ChatId, AccPara, AccFull, AccTool)
                        end, {ParaBuf, FullText, ToolAcc}, Lines),
                    stream_loop(ClientRef, ChatId, BotName, Status, Rest, NewParaBuf, NewFullText, NewToolAcc);
                _ ->
                    %% Non-200: body is an error payload, just accumulate raw for reporting
                    stream_loop(ClientRef, ChatId, BotName, Status, LineBuf, <<ParaBuf/binary, Bin/binary>>, FullText, ToolAcc)
            end
    after 280000 ->
        {error, ollama_stream_timeout}
    end.

handle_line(<<>>, _BotName, _ChatId, ParaBuf, FullText, ToolAcc) ->
    {ParaBuf, FullText, ToolAcc};
handle_line(Line, BotName, ChatId, ParaBuf, FullText, ToolAcc) ->
    #{<<"message">> := Msg} = json:decode(Line),
    case maps:get(<<"tool_calls">>, Msg, undefined) of
        Calls when Calls =:= undefined; Calls =:= [] ->
            Piece = maps:get(<<"content">>, Msg, <<>>),
            Combined = <<ParaBuf/binary, Piece/binary>>,
            NewParaBuf = flush_paragraphs(BotName, ChatId, Combined),
            {NewParaBuf, <<FullText/binary, Piece/binary>>, ToolAcc};
        Calls ->
            %% Tool-call chunks carry no user-facing text; don't flush ParaBuf.
            {ParaBuf, FullText, {Calls, Msg}}
    end.

flush_paragraphs(BotName, ChatId, Buf) ->
    case binary:split(Buf, <<"\n\n">>) of
        [Buf] -> Buf;
        [Para, Rest] ->
            Trimmed = string:trim(Para),
            case Trimmed of
                <<>> -> flush_paragraphs(BotName, ChatId, Rest);
                _ ->
                    send_chunk(BotName, ChatId, Trimmed),
                    flush_paragraphs(BotName, ChatId, Rest)
            end
    end.

split_lines(Bin) ->
    Parts = binary:split(Bin, <<"\n">>, [global]),
    N = length(Parts),
    {Lines, [Rest]} = lists:split(N - 1, Parts),
    {Lines, Rest}.

send_chunk(BotName, ChatId, Text) ->
    case pe4kin:send_message(BotName, #{chat_id => ChatId, text => Text}) of
        {ok, _} -> ok;
        Error -> io:format("OLLAMA STREAM: send failed: ~p~n", [Error])
    end.

%% --- Tool dispatch ---
execute_tools(Calls) ->
    lists:map(fun(#{<<"function">> := Fn}) ->
        Name = maps:get(<<"name">>, Fn),
        %% Note: some models send 'arguments' as a nested JSON string
        Args = case maps:get(<<"arguments">>, Fn) of
            B when is_binary(B) -> json:decode(B);
            M when is_map(M) -> M
        end,
        Result = inky_tools:dispatch(Name, Args),
        #{<<"role">> => <<"tool">>, <<"content">> => Result}
    end, Calls).

handle_cast(_Msg, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.

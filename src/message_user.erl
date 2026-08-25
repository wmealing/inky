-module(message_user).
-behaviour(gen_server).

-export([start_link/1, send/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(CHAT_ID, 118403883).

-record(state, {bot_name}).

%% --- API ---
start_link(BotName) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [BotName], []).

-spec send(unicode:chardata()) -> ok.
send(Message) ->
    gen_server:cast(?MODULE, {send, Message}).

%% --- Callbacks ---
init([BotName]) ->
    {ok, #state{bot_name = BotName}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({send, Message}, State) ->
    deliver(State#state.bot_name, Message),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% --- Internal ---
deliver(BotName, Message) ->
    Text = unicode:characters_to_binary(Message),
    case pe4kin:send_message(BotName, #{chat_id => ?CHAT_ID, text => Text}) of
        {ok, _} ->
            io:format("MESSAGE_USER: sent~n");
        Error ->
            io:format("MESSAGE_USER: send failed: ~p~n", [Error])
    end.

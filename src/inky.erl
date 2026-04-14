%%%-------------------------------------------------------------------
%%% @author Wade Mealing <wmealing@gmail.com>
%%% @copyright (C) 2026, Wade Mealing
%%% @doc
%%%
%%% @end
%%% Created : 31 Jan 2026 by Wade Mealing <wmealing@gmail.com>
%%%-------------------------------------------------------------------
-module(inky).

-behaviour(gen_server).

-include("bot.hrl").

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(POLL_RESTART_DELAY, 5000).  % 5 seconds before retrying
-define(POLL_HEARTBEAT_INTERVAL, 30000).  % Check polling health every 30 seconds
-define(POLL_TIMEOUT, 60000).  % Consider polling dead if no message in 60 seconds

-record(inky_state, {bot_name, poll_ref, poll_timer, last_update_time, heartbeat_timer}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link(State :: #inky_state{}) -> {ok, Pid :: pid()} |
          {error, Error :: {already_started, pid()}} |
          {error, Error :: term()} |
          ignore.
start_link(State) ->
    io:format("INKY START LINK~n"),
    io:format("MODULE: ~p~n", [?MODULE]),
    pe4kin_receiver:subscribe(State#auth_state.name, ?MODULE),
    gen_server:start_link({local, ?SERVER}, ?MODULE, [State], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> {ok, State :: term()} |
          {ok, State :: term(), Timeout :: timeout()} |
          {ok, State :: term(), hibernate} |
          {stop, Reason :: term()} |
          ignore.

init([State]) ->
    % Start polling
    process_flag(trap_exit, true),
    {auth_state,BotName, _Key} = State,
    {PollRef, Timer} = start_polling(BotName),
    HeartbeatTimer = erlang:send_after(?POLL_HEARTBEAT_INTERVAL, self(), check_polling_health),

    {ok, #inky_state{
        bot_name = BotName,
        poll_ref = PollRef,
        poll_timer = Timer,
        last_update_time = erlang:system_time(millisecond),
        heartbeat_timer = HeartbeatTimer}}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), term()}, State :: term()) ->
          {reply, Reply :: term(), NewState :: term()} |
          {reply, Reply :: term(), NewState :: term(), Timeout :: timeout()} |
          {reply, Reply :: term(), NewState :: term(), hibernate} |
          {noreply, NewState :: term()} |
          {noreply, NewState :: term(), Timeout :: timeout()} |
          {noreply, NewState :: term(), hibernate} |
          {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
          {stop, Reason :: term(), NewState :: term()}.
handle_call(_Request, _From, State) ->
    io:format("HANDLING CALL~n"),
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: term()) ->
          {noreply, NewState :: term()} |
          {noreply, NewState :: term(), Timeout :: timeout()} |
          {noreply, NewState :: term(), hibernate} |
          {stop, Reason :: term(), NewState :: term()}.
handle_cast(_Request, State) ->
    io:format("GOT MSG~n",[]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), State :: term()) ->
          {noreply, NewState :: term()} |
          {noreply, NewState :: term(), Timeout :: timeout()} |
          {noreply, NewState :: term(), hibernate} |
          {stop, Reason :: normal | term(), NewState :: term()}.

% Check if polling is still healthy
handle_info(check_polling_health, State) ->
    CurrentTime = erlang:system_time(millisecond),
    TimeSinceLastUpdate = CurrentTime - State#inky_state.last_update_time,

    io:format("INFO: Checking polling health. Time since last update: ~p ms~n", [TimeSinceLastUpdate]),

    case TimeSinceLastUpdate > ?POLL_TIMEOUT of
        true ->
            io:format("WARNING: Polling appears to be dead (no updates in ~p ms). Attempting restart...~n", [?POLL_TIMEOUT]),
            % Schedule immediate restart
            gen_server:cast(self(), restart_polling_now);
        false ->
            io:format("INFO: Polling is healthy~n")
    end,

    % Schedule next health check
    HeartbeatTimer = erlang:send_after(?POLL_HEARTBEAT_INTERVAL, self(), check_polling_health),


    {noreply, State#inky_state{heartbeat_timer = HeartbeatTimer}};

handle_info({pe4kin_update, _, Update}, State) ->
    #{<<"message">> := #{<<"chat">> := #{<<"id">> := ChatId}} = Message} = Update,
    #{<<"text">> :=  Text} = Message,
    #{<<"from">> := #{<<"username">> := Username}} = Message,
    io:format("TEXT: ~p~n", [Text]),
    io:format("USERNAME: ~p~n", [Username]),

    IsValid = validate:for(Username),

    ResponseText =
        case IsValid of
            true ->
                ollama_worker:ask(Text);
            _ ->
                <<"NOT VALID USER - STOP SENDING MESSAGES HERE">>
        end,

    {ok, _What} = pe4kin:send_message(State#inky_state.bot_name, #{chat_id => ChatId, text => ResponseText}),

    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
                State :: term()) -> any().
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term() | {down, term()},
                  State :: term(),
                  Extra :: term()) -> {ok, NewState :: term()} |
          {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Start polling and return reference + timer
%% The timer will trigger a restart if polling fails
start_polling(BotName) ->
    io:format("INFO: Starting HTTP polling for ~p~n", [BotName]),

    % Try to start the polling
    case catch pe4kin_receiver:start_http_poll(BotName, #{limit=>100, timeout=>60}) of
        {'EXIT', Reason} ->
            io:format("ERROR: Failed to start polling: ~p~n", [Reason]),
            % Schedule a retry in POLL_RESTART_DELAY ms
            Timer = erlang:send_after(?POLL_RESTART_DELAY, self(), restart_polling),
            {undefined, Timer};
        Result ->
            io:format("INFO: Polling started successfully: ~p~n", [Result]),
            % No timer needed if successful
            {Result, undefined}
    end.


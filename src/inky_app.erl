%%%-------------------------------------------------------------------
%% @doc inky public API
%% @end
%%%-------------------------------------------------------------------

-module(inky_app).

-behaviour(application).

-export([start/2, stop/1]).

-include("bot.hrl").

start(_StartType, _StartArgs) ->
    {ok, Name} = application:get_env(inky, name),
    {ok, Token} = application:get_env(inky, token),
    BotName = unicode:characters_to_binary(Name),
    BotToken = unicode:characters_to_binary(Token),
    State = #auth_state{name = BotName, token = BotToken},
    pe4kin:launch_bot(State#auth_state.name, State#auth_state.token, #{receiver => true}),
    inky_sup:start_link(State).

stop(_State) ->
    ok.

%% internal functions

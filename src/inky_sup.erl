%%%-------------------------------------------------------------------
%% @doc inky top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(inky_sup).

-behaviour(supervisor).

-include("records.hrl").

-export([start_link/1]).

-export([init/1]).

-define(SERVER, ?MODULE).


start_link(State) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [State]).


%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional


init([]) ->
    io:format("EMPTY BRACKET INIT~n"),
    {ok, {{one_for_one, 3, 5}, []}};


init([State]) ->
    io:format("INKY SUP STATE BRACKET~n"),
    ChildSpecs = [#{id => inky,
                    start => {inky, start_link, [State]},
                    restart => permanent,
                    shutdown => brutal_kill,
                    type => worker,
                    modules => [inky]},
		  #{id => ollama_client,
                    start => {ollama_worker, start_link, [State#auth_state.name]},
                    restart => permanent,
                    shutdown => brutal_kill,
                    type => worker,
                    modules => [ollama_worker]},
		  #{id => message_user,
                    start => {message_user, start_link, [State#auth_state.name]},
                    restart => permanent,
                    shutdown => brutal_kill,
                    type => worker,
                    modules => [message_user]},
		  %% Sensors get their own supervisor so a crash-looping one
		  %% (unplugged hardware, missing device) burns its own restart
		  %% intensity instead of this one's, which would take the bot
		  %% and ollama_worker down with it.
		  #{id => inky_sensor_sup,
                    start => {inky_sensor_sup, start_link, []},
                    restart => permanent,
                    shutdown => infinity,
                    type => supervisor,
                    modules => [inky_sensor_sup]}
	],
    {ok, {{one_for_one, 3, 5}, ChildSpecs}}.

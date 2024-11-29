%%%----------------------------------------------------------------------
%%% File    : ejabberd_app.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : ejabberd's application callback module
%%% Created : 31 Jan 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2011   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_app).
-author('alexey@process-one.net').

-behaviour(application).

-export([start/2, prep_stop/1, stop/1]).

-ignore_xref([prep_stop/1]).

-include("mongoose.hrl").

-type typed_listeners() :: [{Type :: ranch | cowboy, Listener :: ranch:ref()}].


%%%
%%% Application API
%%%

start(normal, _Args) ->
    try
        do_start()
    catch Class:Reason:StackTrace ->
        %% Log a stacktrace because while proc_lib:crash_report/4 would report a crash reason,
        %% it would not report the stacktrace
        ?LOG_CRITICAL(#{what => app_failed_to_start,
                        class => Class, reason => Reason, stacktrace => StackTrace}),
        erlang:raise(Class, Reason, StackTrace)
    end;
start(_, _) ->
    {error, badarg}.

do_start() ->
    mongoose_fips:notify(),
    write_pid_file(),
    update_status_file(starting),
    mongoose_config:start(),
    mongoose_internal_databases:init(),
    mongoose_graphql:init(),
    translate:start(),
    mongoose_graphql_commands:start(),
    mongoose_logs:set_global_loglevel(mongoose_config:get_opt(loglevel)),
    mongoose_deprecations:start(),
    {ok, _} = Sup = ejabberd_sup:start_link(),
    mongoose_system_probes:start(),
    mongoose_router:start(),
    mongoose_wpool:ensure_started(),
    mongoose_wpool:start_configured_pools(),
    %% ejabberd_sm is started separately because it may use one of the outgoing_pools
    %% but some outgoing_pools should be started only with ejabberd_sup already running
    ejabberd_sm:start(),
    ejabberd_auth:start(),
    mongoose_cluster_id:start(),
    mongoose_service:start(),
    mongoose_modules:start(),
    service_mongoose_system_metrics:verify_if_configured(),
    mongoose_listener:start(),
    mongoose_instrument:persist(),
    gen_hook:reload_hooks(),
    update_status_file(started),
    ?LOG_NOTICE(#{what => mongooseim_node_started, version => ?MONGOOSE_VERSION, node => node()}),
    Sup.

%% @doc Prepare the application for termination.
%% This function is called when an application is about to be stopped,
%% before shutting down the processes of the application.
prep_stop(_State) ->
    mongoose_deprecations:stop(),
    TypedListeners = get_typed_listeners(),
    suspend_listeners(TypedListeners),
    StoppedCount = broadcast_c2s_shutdown_sup(),
    StoppedCount2 = broadcast_c2s_shutdown_to_regular_c2s_connections(TypedListeners),
    mongoose_listener:stop(),
    mongoose_modules:stop(),
    mongoose_service:stop(),
    mongoose_wpool:stop(),
    mongoose_graphql_commands:stop(),
    mongoose_router:stop(),
    mongoose_system_probes:stop(),
    #{stopped_count => StoppedCount + StoppedCount2}.

%% All the processes were killed when this function is called
stop(#{stopped_count := StoppedCount}) ->
    mongoose_config:stop(),
    ?LOG_NOTICE(#{what => mongooseim_node_stopped, version => ?MONGOOSE_VERSION,
                  node => node(), stopped_sessions_count => StoppedCount}),
    delete_pid_file(),
    update_status_file(stopped),
    %% We cannot stop other applications inside of the stop callback
    %% (because we would deadlock the application controller process).
    %% That is why we call mnesia:stop() inside of db_init_mnesia() instead.
    ok.

%%%
%%% Internal functions
%%%

-spec suspend_listeners(typed_listeners()) -> ok.
suspend_listeners(TypedListeners) ->
    [ranch:suspend_listener(Ref) || {_Type, Ref} <- TypedListeners],
    ok.

-spec get_typed_listeners() -> typed_listeners().
get_typed_listeners() ->
    Children = supervisor:which_children(mongoose_listener_sup),
    Listeners1 = [{cowboy, ejabberd_cowboy:ref(Listener)}
                  || {Listener, _, _, [ejabberd_cowboy]} <- Children],
    Listeners2 = [{ranch, Ref}
                  || {Ref, _, _, [mongoose_c2s_listener]} <- Children],
    Listeners1 ++ Listeners2.

-spec broadcast_c2s_shutdown_sup() -> StoppedCount :: non_neg_integer().
broadcast_c2s_shutdown_sup() ->
    %% Websocket c2s connections have two processes per user:
    %% - one is websocket Cowboy process.
    %% - one is under mongoose_c2s_sup.
    %%
    %% Regular XMPP connections are not under mongoose_c2s_sup,
    %% they are under the Ranch listener, which is a child of mongoose_listener_sup.
    %%
    %% We could use ejabberd_sm to get both Websocket and regular XMPP sessions,
    %% but waiting till the list size is zero is much more computationally
    %% expensive in that case.
    Children = supervisor:which_children(mongoose_c2s_sup),
    lists:foreach(
        fun({_, Pid, _, _}) ->
            mongoose_c2s:exit(Pid, system_shutdown)
        end,
        Children),
    mongoose_lib:wait_until(
        fun() ->
              Res = supervisor:count_children(mongoose_c2s_sup),
              proplists:get_value(active, Res)
        end,
        0),
    length(Children).

%% Based on https://ninenines.eu/docs/en/ranch/2.1/guide/connection_draining/
-spec broadcast_c2s_shutdown_to_regular_c2s_connections(typed_listeners()) ->
    non_neg_integer().
broadcast_c2s_shutdown_to_regular_c2s_connections(TypedListeners) ->
    Refs = [Ref || {ranch, Ref} <- TypedListeners],
    StoppedCount = lists:foldl(
        fun(Ref, Count) ->
            Conns = ranch:procs(Ref, connections),
            [mongoose_c2s:exit(Pid, system_shutdown) || Pid <- Conns],
            length(Conns) + Count
        end, 0, Refs),
    lists:foreach(
        fun(Ref) ->
            ok = ranch:wait_for_connections(Ref, '==', 0)
        end, Refs),
    StoppedCount.

%%%
%%% PID file
%%%

-spec write_pid_file() -> 'ok' | {'error', atom()}.
write_pid_file() ->
    case ejabberd:get_pid_file() of
        false ->
            ok;
        PidFilename ->
            write_pid_file(os:getpid(), PidFilename)
    end.

-spec write_pid_file(Pid :: string(),
                     PidFilename :: nonempty_string()
                    ) -> 'ok' | {'error', atom()}.
write_pid_file(Pid, PidFilename) ->
    case file:open(PidFilename, [write]) of
        {ok, Fd} ->
            io:format(Fd, "~s~n", [Pid]),
            file:close(Fd);
        {error, Reason} ->
            ?LOG_ERROR(#{what => cannot_write_to_pid_file,
                         pid_file => PidFilename, reason => Reason}),
            throw({cannot_write_pid_file, PidFilename, Reason})
    end.

update_status_file(Status) ->
    case ejabberd:get_status_file() of
        false ->
            ok;
        StatusFilename ->
            file:write_file(StatusFilename, atom_to_list(Status))
    end.

-spec delete_pid_file() -> 'ok' | {'error', atom()}.
delete_pid_file() ->
    case ejabberd:get_pid_file() of
        false ->
            ok;
        PidFilename ->
            file:delete(PidFilename)
    end.

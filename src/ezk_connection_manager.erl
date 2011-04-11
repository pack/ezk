%% -------------------------------------------------------------------
%%
%% ezk_connection_manager: manages the ezk_connections
%%
%% Copyright (c) 2011 Marco Grebe. All Rights Reserved.
%% Copyright (c) 2011 global infinipool GmbH.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(ezk_connection_manager).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([start_connection/0, start_connection/1, start_connection/2, end_connection/2]).
-export([add_monitors/2]).

-include_lib("../include/ezk.hrl").

-define(SERVER, ?MODULE).

%% starts the server. normally called by the supervisor of the ezk application.
start_link(Args) ->
    gen_server:start_link({local,?SERVER}, ?MODULE, Args, []).

%% Makes the first State, which stores the default servers. 
init(DefaultServers) ->	
    {ok, #con_man_state{defaultserverlist = DefaultServers,
			connections       = [],
			monitorings       = []
		       }}.

%% starts a connection by using the default servers. Returns 
%% {ok, PId} if everything works. 
start_connection() ->
    gen_server:call(?SERVER, {start_connection, [], []}).
%% starts a connection by using a special serverlist.
%% if serverlist is empty the default servers are used. 
start_connection(Servers) ->
    gen_server:call(?SERVER, {start_connection, Servers, []}).
start_connection(Servers, MonitorPIds) ->
    gen_server:call(?SERVER, {start_connection, Servers, MonitorPIds}).

%% ends the connection symbolized by the PId. Returns ok or an error message
end_connection(ConnectionPId, Reason) ->
    ?LOG(3, "Connection manager: Sending endconn message to myself"),
    gen_server:call(?SERVER, {end_connection, ConnectionPId, Reason}).

add_monitors(ConnectionPId, MonitorPIds) ->
    gen_server:call(?SERVER, {add_monitors, ConnectionPId, MonitorPIds}).

%% handles the call generated by the function "start_connection/0 or 1.
%% Looks if a new Serverlist is given. If not uses Default Servers.
%% Then starts the connection an adds it to the connections list.
handle_call({start_connection, Servers, MonitorPIds}, _From, State) ->
    case Servers of
	[] ->
	    UsedServers = State#con_man_state.defaultserverlist;
	_Else -> 
	    UsedServers = Servers
    end,
    {ok, ConnectionPId} = ezk_connection:start(UsedServers),
    Monitors = activate_usable_monitors(MonitorPIds),	   
    OldConnectionList   = State#con_man_state.connections,
    NewConnectionList   = [{ConnectionPId, Monitors} | OldConnectionList], 
    NewState            = State#con_man_state{connections = NewConnectionList},
    {reply, {ok, ConnectionPId} , NewState};
%% Handles calls generated by end_connection. 
%% Calls the function die of the connection symbolized by the PId.
handle_call({end_connection, ConnectionPId, Reason},  _From, State) ->
    ?LOG(3, "COnnection manager: got the endcon message."),
    Reply = ezk:die(ConnectionPId, Reason),
    OldConnections = State#con_man_state.connections,
    NewConnections = lists:keydelete(ConnectionPId, 1, OldConnections),
    NewState = State#con_man_state{connections = NewConnections},
    {reply, Reply, NewState};
%% Add new Monitors. Monitor PIds is a list of PIds whose death should lead to  
%% the termination of the corresponding Connection.
handle_call({add_monitors, ConnectionPId, MonitorPIds}, _From, State) ->
    OldConnections = State#con_man_state.monitorings,
    NewConnections = add_monitors_to_connection(ConnectionPId, MonitorPIds, OldConnections),
    NewState    = State#con_man_state{connections = NewConnections},
    {reply, ok, NewState}.

handle_cast(_Mes, State) ->
    {noreply, State}.

%% This message arrives if one of the monitored processes dies. 
%% When this happens the corresponding Connection is searched
%% and then ended.
handle_info({'DOWN', MonitorRef, _Type, _Object, _Info}, State) ->
    Connections = State#con_man_state.connections,
    case get_conpid_to_monref(MonitorRef, Connections) of 
	{ok, ConPId} ->
	    spawn(fun() ->
			  end_connection(ConPId, "Essential Process Died") end),
	    {noreply, State};
	_Else ->
	    {noreply, State}
    end.

%% gets the connectionlist and searches for the connection pid which corresponds to the 
%% given monitor reference
get_conpid_to_monref(MonitorRef, Connections) ->
    ShortenedConnections = lists:map(fun({ConPId, Mons}) ->
					     is_monref_included(MonitorRef, ConPId, Mons)
				     end,
				     Connections),
    lists:keyfind(ok, 1, ShortenedConnections).

%% if monitor is in the list returns {ok, ConPID}, else error.
is_monref_included(MonitorRef, ConnectionPId, [MonitorRef | _L]) ->
    {ok, ConnectionPId};
is_monref_included(_MonitorRef, _ConnectionPId, []) -> 
    error;
is_monref_included(MonitorRef, ConnectionPId, [_Something | List]) ->
    is_monref_included(MonitorRef, ConnectionPId, List).

%% Adds a Monitor for a given Connection Id in the corresponding list.
add_monitors_to_connection(ConnectionPId, MonitorPIds, [{ConnectionPId, Mons} | Cons]) ->
    Monitors = activate_usable_monitors(MonitorPIds),	   
    [{ConnectionPId, Monitors ++ Mons} | Cons];
add_monitors_to_connection(_ConnectionPId, _MonitorPIds, []) ->
    [];
add_monitors_to_connection(ConnectionPId, MonitorPIds, [Something | Cons]) ->
    [Something | add_monitors_to_connection(ConnectionPId, MonitorPIds, Cons)].

%% scans for real PIds and activates a monitor for each one found. 
%% returns a list of monitor references.
activate_usable_monitors(MonitorPIds) ->
    MonitorPre          = lists:filter(fun(I) -> is_pid(I) end, MonitorPIds),
    Monitors            = lists:map(fun(I) -> 
					    erlang:monitor(process, I)
				    end, MonitorPre),	   
    Monitors.    
    
%% The terminate function trys to kill all connections bevore ending.
terminate(Reason, State) ->
    lists:map(fun(PId) ->
		      ezk:die(PId, Reason) end,
	      State#con_man_state.connections).
    
    

%% the needed swap function. 
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

    

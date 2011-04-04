%% -------------------------------------------------------------------
%%
%% ezk_connection: A GenServer to manage the connection. It has the access to the 
%%                 Socket (stored in the State), keeps track of send requests,
%%                 and manages the watches. The Main Module.
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

-module(ezk_connection).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3, addauth/2]).
%normal functions
-export([  create/2,   create/3,   create/4,   delete/1,   set/2,   set_acl/2]).
-export([n_create/4, n_create/5, n_create/6, n_delete/3, n_set/4, n_set_acl/4]).
-export([  get/1,   get_acl/1,   ls2/1,   ls/1, die/1]).
-export([n_get/3, n_get_acl/3, n_ls2/3, n_ls/3]).
%functions dealing with watches
-export([ls/3, get/3, ls2/3]).
%macros
-export([delete_all/1, ensure_path/1]).
%infos
-export([info_get_iterations/0]).

-export([get_prefix_paths/1]).

-include_lib("../include/ezk.hrl").

-define(SERVER, ?MODULE). 
-define(HEARTBEATTIME, 10000).

start_link(Args) ->
    ?LOG(1,"Connection: Start link called with Args: ~w",[Args]),
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).


%% inits the random function and chooeses a Server from the list.
%% then establishes a connection to that server.
%% returns {ok, State} or {error, ErrorMessage} or {unknown, Message, ErrorCode}
init(Servers) ->
    random:seed(erlang:now()),
    ?LOG(1,"Connect init : incomming args: ~w",[Servers]),
    WhichServer = random:uniform(length(Servers)),
    ?LOG(0,"Choose server ~w",[WhichServer]),
    {Ip, Port, WantedTimeout} =  lists:nth(WhichServer, Servers),
    establish_connection(Ip, Port, WantedTimeout).
    
%% Kills the Server (not the supervisor!)
die(Reason) -> 
    gen_server:call(?SERVER, {exit, Reason}).

%%--------------------------- Zookeeper Functions ---------------------
%% All Return {ok, Reply} if it worked.

%% Reply = authed 
%% Returns {error, auth_in_progress}  if the authslot is already in use.
%% Returns {error, auth_failed} if server rejected auth
%% Returns {error, unknown, ErrorCodeBin} if something new happened
addauth(Scheme, Auth) ->
   gen_server:call(?SERVER, {addauth, Scheme, Auth}).

%% Creates a new ZK_Node
%% Reply = Path where Path = String
create(Path, Data) ->
   gen_server:call(?SERVER, {command, {create, Path, Data, [], [undef]}}).
n_create(Path, Data, Receiver, Tag) ->
   gen_server:cast(?SERVER, {nbcommand, {create, Path, Data, [], [undef]}, Receiver, Tag}).
%% Typ = e | s | es (stands for etheremal, sequenzed or both)
create(Path, Data, Typ) ->
   gen_server:call(?SERVER, {command, {create, Path, Data, Typ, [undef]}}).
n_create(Path, Data, Typ, Receiver, Tag) ->
   gen_server:cast(?SERVER, {nbcommand, {create, Path, Data, Typ, [undef]}, Receiver, Tag}).
%% Acls = [Acl] where Acl = {Scheme, Id, Permission} 
%% with Scheme and Id = String
%% and Permission = [Per] | String 
%% where Per = r | w | c | d | a
create(Path, Data, Typ, Acls)  ->
   gen_server:call(?SERVER, {command, {create, Path, Data, Typ, Acls}}).
n_create(Path, Data, Typ, Acls, Receiver, Tag)  ->
   gen_server:cast(?SERVER, {nbcommand, {create, Path, Data, Typ, Acls}, Receiver, Tag}).

ensure_path(Path) ->
    macro_ensure_path(Path).

%% Deletes a ZK_Node
%% Only working if Node has no children.
%% Reply = Path where Path = String
delete(Path) ->
   gen_server:call(?SERVER, {command, {delete,  Path, []}}).
n_delete(Path, Receiver, Tag) ->
   gen_server:cast(?SERVER, {nbcommand, {delete,  Path, []}, Receiver, Tag}).

%% Deletes a ZK_Node and all his childs.
%% Reply = Path where Path = String
%% If deleting some nodes violates the acl
%% or gets other errors the function tries the
%% other nodes befor giving the error back, so a 
%% maximum number of nodes is deleted.
delete_all(Path) ->
   macro_delete_all_childs(Path).    

%% Reply = {Data, Parameters} where Data = The Data stored in the Node
%% and Parameters = [{ParameterName, Value}]
%% where ParameterName = czxid | mzxid | pzxid | ctime | mtime | dataversion | 
%%                       datalength | number_children | cversion | aclversion
get(Path) ->
   gen_server:call(?SERVER, {command, {get, Path}}).
n_get(Path, Receiver, Tag) ->
   gen_server:cast(?SERVER, {command, {get, Path}, Receiver, Tag}).
%% Like the one above but sets a datawatch to Path.
%% If watch is triggered a Message M is send to the PId WatchOwner
%% M = {WatchMessage, {Path, Type, SyncCon}
%% with Type = child
get(Path, WatchOwner, WatchMessage) ->
    gen_server:call(?SERVER, {watchcommand, {get, getw, Path, {data, WatchOwner,
							       WatchMessage}}}).

%% Returns the actual Acls of a Node
%% Reply = {[ACL],Parameters} with ACl and Parameters like above
get_acl(Path) ->
    gen_server:call(?SERVER, {command, {get_acl, Path}}).
n_get_acl(Path, Receiver, Tag) ->
    gen_server:cast(?SERVER, {command, {get_acl, Path}, Receiver, Tag}).

%% Sets new Data in a Node. Old ones are lost.
%% Reply = Parameters with Data like at get
set(Path, Data) ->
   gen_server:call(?SERVER, {command, {set, Path, Data}}).
n_set(Path, Data, Receiver, Tag) ->
   gen_server:cast(?SERVER, {command, {set, Path, Data}, Receiver, Tag}).

%% Sets new Acls in a Node. Old ones are lost.
%% ACL like above.
%% Reply = Parameters with Data like at get
set_acl(Path, Acls) ->
    gen_server:call(?SERVER, {command, {set_acl, Path, Acls}}).
n_set_acl(Path, Acls, Receiver, Tag) ->
    gen_server:cast(?SERVER, {command, {set_acl, Path, Acls}, Receiver, Tag}).

%% Lists all Children of a Node. Paths are given as Binarys!
%% Reply = [ChildName] where ChildName = <<"Name">>
ls(Path) ->
   gen_server:call(?SERVER, {command, {ls, Path}}).
n_ls(Path, Receiver, Tag) ->
   gen_server:cast(?SERVER, {nbcommand, {ls, Path}, Receiver, Tag}).
%% like above, but a Childwatch is set to the Node. 
%% Same Reaktion like at get with watch but Type = child
ls(Path, WatchOwner, WatchMessage) ->
    ?LOG(3,"Connection: Send lsw"),
    gen_server:call(?SERVER, {watchcommand, {ls, lsw,  Path, {child, WatchOwner, 
							      WatchMessage}}}).

%% Lists all Children of a Node. Paths are given as Binarys!
%% Reply = {[ChildName],Parameters} with Parameters and ChildName like above.
ls2(Path) ->
   gen_server:call(?SERVER, {command, {ls2, Path}}).
n_ls2(Path, Receiver, Tag) ->
   gen_server:cast(?SERVER, {command, {ls2, Path}, Receiver, Tag}).
%% like above, but a Childwatch is set to the Node. 
%% Same Reaktion like at get with watch but Type = child
ls2(Path, WatchOwner, WatchMessage) ->
    gen_server:call(?SERVER, {watchcommand, {ls2, ls2w, Path ,{child, WatchOwner, 
							       WatchMessage}}}).

%% Returns the Actual Transaction Id of the Client.
%% Reply = Iteration = Int.
info_get_iterations() ->
    gen_server:call(?SERVER, {info, get_iterations}).

%% Handles calls for Number of Iteration
handle_call({info, get_iterations}, _From, State) ->
    {reply, {ok, State#cstate.iteration}, State};
handle_call({info, get_watches}, _From, State) ->
    {reply, {ok, ets:first(State#cstate.watchtable)}, State};
%% Handles normal commands (get/1, set/2, ...) by
%% a) determinate the corresponding packet to send this request to zk_server
%% b) Save that the Request was send in the open_requests dict (key: actual iteration)
%% c) set noreply. Real answer is triggered by incoming tcp message
handle_call({command, Args}, From, State) ->
    Iteration = State#cstate.iteration,
    {ok, CommId, Path, Packet} = ezk_message_2_packet:make_packet(Args, Iteration),
    gen_tcp:send(State#cstate.socket, Packet),
    ?LOG(1, "Connection: Packet send"),
    NewOpen  = dict:store(Iteration, {CommId, Path, {blocking, From}}, State#cstate.open_requests),
    ?LOG(3, "Connection: Saved open Request."),
    NewState = State#cstate{iteration = Iteration+1, open_requests = NewOpen },    
    ?LOG(3, "Connection: Returning to wait status"),  
    {noreply, NewState};
%% Handles commands which set a watch(get/3, ls/3, ...) by
%% a) Save an entry in the watchtable (key: {Typ, Path})
%% b) Look up if already a watch of this type is set to the node.
%% c) if yes the command is user without setting a new one.
handle_call({watchcommand, {Command, CommandW, Path, {WType, WO, WM}}}, From, State) ->
    ?LOG(1," Connection: Got a WatchSetter"),
    Watchtable = State#cstate.watchtable,
    AllIn = ets:lookup(Watchtable, {WType,Path}),
    ?LOG(3," Connection: Searched Table"),
    true = ets:insert(Watchtable, {{WType, Path}, WO, WM}),
    ?LOG(3," Connection: Inserted new Entry: ~w",[{{WType, Path}, WO, WM}]),
    case AllIn of
	[] -> 
	    ?LOG(3," Connection: Search got []"),
	    handle_call({command, {CommandW, Path}}, From, State);
	_Else -> 
	    ?LOG(3," Connection: Already Watches set to this path/typ"),
	    handle_call({command, {Command, Path}}, From, State)
    end;
%% Handles orders to die by dying
handle_call({exit, Reason}, _From, _State) ->
    Self = self(),
    erlang:exit(Self, Reason);
%% Handles auth requests
handle_call({addauth, Scheme, Auth}, From, State) ->
    OutstandingAuths = State#cstate.outstanding_auths,
    case OutstandingAuths of
	1 ->
	    {reply,  {error, auth_in_progress}, State};
	0 ->
	    {ok, Packet} = ezk_message_2_packet:make_addauth_packet({add_auth, Scheme,
								     Auth}),
	    gen_tcp:send(State#cstate.socket, Packet),
	    NewOpen  = dict:store(auth, From, State#cstate.open_requests),
	    NewState = State#cstate{outstanding_auths = 1, open_requests = NewOpen },   
	    {noreply, NewState}
    end.
    
handle_cast({nbcommand, Args, Receiver, Tag}, State) ->
    Iteration = State#cstate.iteration,
    {ok, CommId, Path, Packet} = ezk_message_2_packet:make_packet(Args, Iteration),
    gen_tcp:send(State#cstate.socket, Packet),
    ?LOG(1, "Connection: Packet send"),
    NewOpen  = dict:store(Iteration, {CommId, Path, {nonblocking, Receiver, Tag}},
			  State#cstate.open_requests),
    ?LOG(3, "Connection: Saved open Request."),
    NewState = State#cstate{iteration = Iteration+1, open_requests = NewOpen },    
    ?LOG(3, "Connection: Returning to wait status"),  
    {noreply, NewState}.

%% tcp events arrive
%% parses the first part of the message and determines of which type it is and then does
%% the corresponding (see below).
handle_info({tcp, _Port, Info}, State) ->
    ?LOG(1, "Connection: Got a message from Server"), 
    TypedMessage = ezk_packet_2_message:get_message_typ(Info), 
    ?LOG(3, "Connection: Typedmessage is ~w",[TypedMessage]),     
    handle_typed_incomming_message(TypedMessage, State);

%% Its time to let the Heart bump one more time
handle_info(heartbeat, State) ->
    case State#cstate.outstanding_heartbeats of
	%% if there is no outstanding Heartbeat everything is ok.
	%% The new beat is send and a notice left when the next bump is scheduled
	0 ->
            ?LOG(4, "Send a Heartbeat"),
            Heartbeat = << 255,255,255,254, 11:32>>,
	    gen_tcp:send(State#cstate.socket, Heartbeat),
            NewState = State#cstate{outstanding_heartbeats = 1},
	    erlang:send_after(?HEARTBEATTIME, self(), heartbeat),
	    {noreply, NewState};
	%% Last bump got no reply. Thats bad.
        _Else ->
	    die("Heartattack")
    end.

%% if server dies all owners who are waiting for watchevents get a Message
%% M = {watchlost, WatchMessage, Data}.
%% All Outstanding requests are answered with {error, client_broke, CommId, Path}
terminate(_Reason, State) ->
    Watchtable = State#cstate.watchtable,
    AllWatches = ets:match(Watchtable, '$1'),
    lists:map(fun({Data, WO, WM}) -> 
		      WO ! {watchlost, WM, Data} 
	      end, AllWatches),

    OpenRequests = State#cstate.open_requests,
    Keys = dict:fetch_keys(OpenRequests),
    lists:map(fun(Key) -> 
		      {CommId, Path, From}  = dict:fetch(Key, OpenRequests),
		      From ! {error, client_broke, CommId, Path}
	      end, Keys),
    ?LOG(1,"Connection: TERMINATING"),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Updates the Watchtable if a watchevent arrived and sends the Message to the owner
send_watch_events_and_erase_receivers(Table, Receivers, Path, Typ, SyncCon) ->
    case Receivers of
	[] ->
            ?LOG(1, "Connection: Receiver List completely processed"),
	    ok;
	[{Key, WatchOwner, WatchMessage}|T] ->
            ?LOG(1, "Connection: Send something to ~w", [WatchOwner]),
            WatchOwner ! {WatchMessage, {Path, Typ, SyncCon}},
	    ets:delete(Table, Key),
	    send_watch_events_and_erase_receivers(Table, T, Path, Typ, SyncCon)
    end.       

macro_ensure_path(Path) ->
    FolderList = string:tokens(Path, "/"),
    PrefixPaths = get_prefix_paths(FolderList),
    lists:map(fun(Folder) -> ensure_folder(Folder) end, PrefixPaths),
    ls(Path).

get_prefix_paths([]) ->
    [];
get_prefix_paths([ Head | Tail]) ->
    PrefixTails = get_prefix_paths(Tail),
    HeadedPrefixTails = lists:map(fun(PathTail) ->
					   ("/"++ Head++ PathTail) end, PrefixTails),
    ["/" ++ Head | HeadedPrefixTails].

	      
ensure_folder(PrefixPath) ->
    case ls(PrefixPath) of
	{ok, _I} ->
	    ok;
	{error, _I} ->
	    create(PrefixPath, "Created by ensure_path macro")
    end.

%% A Macro which deletes a Node and all his Childs.
%% a) List children of Node. If he has none everything is all right.
%% b) If he has some: kill them and their Children rekursively.
%% c) Kill the Node with delete
macro_delete_all_childs(Path) ->
    ?LOG(3, "Delete All: Trying to Erase ~s",[Path]),
    Childs = ls(Path),
    case Childs of
        {ok, []} ->
	    ?LOG(3, "Killing ~s",[Path]),
	    delete(Path);
	{ok, ListOfChilds} ->
	    ?LOG(3, "Delete All: List of Childs: ~s",[ListOfChilds]),
            case Path of
		"/" ->
		    lists:map(fun(A) ->
				      (delete_all(Path++(binary_to_list(A))))
			      end, ListOfChilds);
		_Else  -> 
		    lists:map(fun(A) ->
				      (delete_all(Path++"/"++(binary_to_list(A)))) 
                              end, ListOfChilds)

	    end,
            ?LOG(3, "Killing ~s",[Path]),
            delete(Path);
	{error, Message} ->
	    {error, Message}
    end.

%% Sets up a connection, performs the Handshake and saves the data to the initial State 
establish_connection(Ip, Port, WantedTimeout) ->
    ?LOG(1, "Connection: Server starting"),
    ?LOG(3, "Connection: IP: ~s , Port: ~w, Timeout: ~w.",[Ip,Port,WantedTimeout]),    
    {ok, Socket} = gen_tcp:connect(Ip,Port,[binary,{packet,4}]),
    ?LOG(3, "Connection: Socket open"),    
    HandshakePacket = <<0:64, WantedTimeout:64, 0:64, 16:64, 0:128>>,
    ?LOG(3, "Connection: Handshake build"),    
    ok = gen_tcp:send(Socket, HandshakePacket),
    ?LOG(3, "Connection: Handshake send"),    
    ok = inet:setopts(Socket,[{active,once}]),
    ?LOG(3, "Connection: Channel set to Active"),    
    receive
	{tcp,Socket,Reply} ->
	    ?LOG(3, "Connection: Handshake Reply there"),    
	    <<RealTimeout:64, SessionId:64, 16:32, _Hash:128>> = Reply,
	    Watchtable = ets:new(watchtable, [duplicate_bag, private]),
	    InitialState  = #cstate{  
	      socket = Socket, ip = Ip, 
	      port = Port, timeout = RealTimeout,
	      sessionid = SessionId, iteration = 1,
	      watchtable = Watchtable},   
	    ?LOG(3, "Connection: Initial state build"),         
	    ok = inet:setopts(Socket,[{active,once}]),
	    ?LOG(3, "Connection: Startup complete",[]),
	    ?LOG(3, "Connection: Initial State : ~w",[InitialState])
    end,
    erlang:send_after(?HEARTBEATTIME, self(), heartbeat),
    ?LOG(3,"Connection established with server ~s, ~w ~n",[Ip, Port]),
    {ok, InitialState}.

%%% heartbeatreply: decrement the number of outstanding Heartbeats.
handle_typed_incomming_message({heartbeat,_HeartBeat}, State) -> 
    ?LOG(4, "Got a Heartbeat"),
    Outstanding = State#cstate.outstanding_heartbeats,
    NewState = State#cstate{outstanding_heartbeats = Outstanding-1},
    ok = inet:setopts(State#cstate.socket,[{active,once}]),
    {noreply, NewState};    
%%% Watchevents happened:
%%% a) parse it by using get_watch_data
%%% b) Look at the watchtable if this event was supposed to arive
%%% c) use send_... to send the event to the owner
handle_typed_incomming_message({watchevent, Payload}, State) ->
    ?LOG(1,"Connection: A Watch Event arrived. Halleluja"),
    {Typ, Path, SyncCon} = ezk_packet_2_message:get_watch_data(Payload), 
    Watchtable = State#cstate.watchtable,
    ?LOG(3,"Connection: Got the data of the watchevent: ~w",[{Typ, Path, SyncCon}]),
    Receiver = ets:lookup(Watchtable, {Typ, Path}),
    ?LOG(3,"Connection: Receivers are: ~w",[Receiver]),
    ok = send_watch_events_and_erase_receivers(Watchtable, Receiver, Path,
					       Typ, SyncCon),
    ?LOG(3,"Connection: the first element in WT ~w",[ets:first(Watchtable)]), 
    ?LOG(3,"Connection: Receivers notified"),
    ok = inet:setopts(State#cstate.socket,[{active,once}]),
    {noreply, State};
%%% Answers to normal requests (set, get,....)
%%% a) Look at the dict if there is a corresponding open request
%%% b) Erase it
%%% c) Parse the Payload 
%%% d) Send the answer
handle_typed_incomming_message({normal, MessId, _Zxid, PayloadWithErrorcode}, State) ->
    ?LOG(3, "Connection: Normal Message"),  
    {ok, {CommId, Path, From}}  = dict:find(MessId, State#cstate.open_requests),
    ?LOG(3, "Connection: Found dictonary entry"),
    NewDict = dict:erase(MessId, State#cstate.open_requests),
    NewState = State#cstate{open_requests = NewDict},
    ?LOG(3, "Connection: Dictionary updated"),
    Reply = ezk_packet_2_message:replymessage_2_reply(CommId, Path,
						      PayloadWithErrorcode),
    ?LOG(3, "Connection: determinated reply"),
    ok = inet:setopts(State#cstate.socket,[{active,once}]),
    case From of
	{blocking, PId} ->
	    gen_server:reply(PId, Reply);
	{nonblocking, ReceiverPId, Tag} ->
	    ReceiverPId ! {Tag, Reply}
    end,
    {noreply, NewState};
%%% Answers to a addauth. 
%%% if there is an errorcode then there wa an error. if not there wasn't
handle_typed_incomming_message({authreply, Errorcode}, State) ->
    {ok, From}  = dict:find(auth, State#cstate.open_requests),
    case Errorcode of
	<<0,0,0,0>> ->
	    Reply = {ok, authed};
	<<255,255,255,141>> ->
	    Reply = {error, auth_failed};
	Else  -> 
	    Reply = {error, unknown, Else}
    end,
    gen_server:reply(From, Reply),
    NewDict = dict:erase(auth, State#cstate.open_requests),
    NewState = State#cstate{open_requests = NewDict, outstanding_auths = 0},
    {noreply, NewState}.




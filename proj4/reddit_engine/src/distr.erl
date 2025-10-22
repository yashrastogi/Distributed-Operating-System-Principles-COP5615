-module(distr).
-export([start_short/1, set_cookie_erlang/2, get_cookie/0, ping/1, 
         whereis_remote/2, send_message/2, register_global/2, register_local/2,
         whereis_global/1, list_nodes/0, list_global_names/0, 
         send_to_named_subject/3, atom_to_name/1]).

start_short(ShortName) ->
    net_kernel:start([list_to_atom(ShortName), longnames]),
    true.


set_cookie_erlang(NodeName, Cookie) ->
    erlang:set_cookie(list_to_atom(NodeName), list_to_atom(Cookie)),
    true.

ping(NodeName) ->
    net_adm:ping(list_to_atom(NodeName)).

get_cookie() ->
    erlang:get_cookie().

% Get the PID of a registered process on a remote node
% Returns {ok, Pid} or {error, not_found}
whereis_remote(RegisteredName, NodeName) ->
    Node = list_to_atom(NodeName),
    Name = list_to_atom(RegisteredName),
    case rpc:call(Node, erlang, whereis, [Name]) of
        Pid when is_pid(Pid) -> {ok, Pid};
        undefined -> {error, not_found};
        {badrpc, Reason} -> {error, Reason}
    end.

% Send a message to a PID (can be local or remote)
send_message(Pid, Message) ->
    erlang:send(Pid, Message),
    ok.

% Register a process globally (accessible from all connected nodes)
register_global(Name, Pid) ->
    NameAtom = list_to_atom(Name),
    case global:register_name(NameAtom, Pid) of
        yes -> {ok, registered};
        no -> {error, already_registered}
    end.

% Register a process locally (only on this node)
register_local(Name, Pid) ->
    NameAtom = list_to_atom(Name),
    try
        register(NameAtom, Pid),
        {ok, registered}
    catch
        error:badarg -> {error, already_registered}
    end.

% Find a globally registered process
whereis_global(Name) ->
    NameAtom = list_to_atom(Name),
    case global:whereis_name(NameAtom) of
        Pid when is_pid(Pid) -> {ok, Pid};
        undefined -> {error, not_found}
    end.

% List all connected nodes
list_nodes() ->
    [node() | nodes()].

% List all globally registered names
list_global_names() ->
    global:registered_names().

% Send to a named subject on a remote node
% Named subjects expect messages in the format {Name, Message}
send_to_named_subject(Pid, RegisteredName, Message) ->
    Name = list_to_atom(RegisteredName),
    % Named subjects expect {Name, Message} format
    erlang:send(Pid, {Name, Message}),
    ok.

atom_to_name(Atom) -> 
    Atom.
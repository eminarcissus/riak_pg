%% @author Christopher Meiklejohn <christopher.meiklejohn@gmail.com>
%% @copyright 2013 Christopher Meiklejohn.
%% @doc Memberships vnode.

-module(riak_pg_memberships_vnode).
-author('Christopher Meiklejohn <christopher.meiklejohn@gmail.com>').

-behaviour(riak_core_vnode).

-include_lib("riak_pg.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

-export([start_vnode/1,
         init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_exit/3]).

-export([join/4,
         leave/4]).

-export([repair/3]).

-record(state, {partition, groups}).

%% API
start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

init([Partition]) ->
    {ok, #state{partition=Partition, groups=dict:new()}}.

%% @doc Join group.
join(Preflist, Identity, Group, Pid) ->
    riak_core_vnode_master:command(Preflist,
                                   {join, Identity, Group, Pid},
                                   {fsm, undefined, self()},
                                   riak_pg_memberships_vnode_master).

%% @doc Leave group.
leave(Preflist, Identity, Group, Pid) ->
    riak_core_vnode_master:command(Preflist,
                                   {leave, Identity, Group, Pid},
                                   {fsm, undefined, self()},
                                   riak_pg_memberships_vnode_master).

%% @doc Perform repair.
repair(IndexNode, Group, Pids) ->
    riak_core_vnode_master:command(IndexNode,
                                   {repair, Group, Pids},
                                   ignore,
                                   riak_pg_memberships_vnode_master).

%% @doc Perform join as part of repair.
handle_command({repair, Group, Pids},
               _Sender,
               #state{groups=Groups0, partition=Partition}=State) ->
    %% Generate key for gproc.
    Key = riak_pg_gproc:key(Group, Partition),

    %% Store back into the dict.
    Groups = dict:store(Group, Pids, Groups0),

    %% Save to gproc.
    ok = riak_pg_gproc:store(Key, Pids),

    {noreply, State#state{groups=Groups}};

%% @doc Respond to a join request.
handle_command({join, {ReqId, _}, Group, Pid},
               _Sender,
               #state{groups=Groups0, partition=Partition}=State) ->
    %% Generate key for gproc.
    Key = riak_pg_gproc:key(Group, Partition),

    %% Find existing list of Pids, and add object to it.
    Pids0 = pids(Groups0, Group, riak_dt_orset:new()),
    Pids = riak_dt_orset:update({add, Pid}, Partition, Pids0),

    %% Store back into the dict.
    Groups = dict:store(Group, Pids, Groups0),

    %% Save to gproc.
    ok = riak_pg_gproc:store(Key, Pids),

    %% Return updated groups.
    {reply, {ok, ReqId}, State#state{groups=Groups}};

%% @doc Respond to a leave request.
handle_command({leave, {ReqId, _}, Group, Pid},
               _Sender,
               #state{groups=Groups0, partition=Partition}=State) ->
    %% Generate key for gproc.
    Key = riak_pg_gproc:key(Group, Partition),

    %% Find existing list of Pids, and add object to it.
    Pids0 = pids(Groups0, Group, riak_dt_orset:new()),
    Pids = riak_dt_orset:update({remove, Pid}, Partition, Pids0),

    %% Store back into the dict.
    Groups = dict:store(Group, Pids, Groups0),

    %% Save to gproc.
    ok = riak_pg_gproc:store(Key, Pids),

    {reply, {ok, ReqId}, State#state{groups=Groups}};

%% @doc Default handler.
handle_command(Message, _Sender, State) ->
    ?PRINT({unhandled_command, Message}),
    {noreply, State}.

%% @doc Fold over the dict for handoff.
handle_handoff_command(?FOLD_REQ{foldfun=Fun, acc0=Acc0}, _Sender, State) ->
    Acc = dict:fold(Fun, Acc0, State#state.groups),
    {reply, Acc, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

%% @doc Handle receiving data from handoff.  Decode data and
%%      perform join/leave.
handle_handoff_data(Data,
                    #state{groups=Groups0, partition=Partition}=State) ->
    {Group, Pids} = binary_to_term(Data),

    %% Generate key for gproc.
    Key = riak_pg_gproc:key(Group, Partition),

    %% Find existing list of Pids, and add object to it.
    Pids0 = pids(Groups0, Group, riak_dt_orset:new()),
    MPids = riak_dt_orset:merge(Pids, Pids0),

    %% Store back into the dict.
    Groups = dict:store(Group, MPids, Groups0),

    %% Save to gproc.
    ok = riak_pg_gproc:store(Key, MPids),

    {reply, ok, State#state{groups=Groups}}.

encode_handoff_item(Group, Pids) ->
    term_to_binary({Group, Pids}).

is_empty(#state{groups=Groups}=State) ->
    case dict:size(Groups) of
        0 ->
            {true, State};
        _ ->
            {false, State}
    end.

delete(State) ->
    {ok, State}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

%% @doc Return pids from the dict.
-spec pids(dict(), atom(), term()) -> term().
pids(Groups, Group, Default) ->
    case dict:find(Group, Groups) of
        {ok, Object} ->
            Object;
        _ ->
            Default
    end.
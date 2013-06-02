%% @author Christopher Meiklejohn <christopher.meiklejohn@gmail.com>
%% @copyright 2013 Christopher Meiklejohn.
%% @doc Publish FSM.

-module(riak_pubsub_publish_fsm).
-author('Christopher Meiklejohn <christopher.meiklejohn@gmail.com>').

-behaviour(gen_fsm).

-include_lib("riak_pubsub.hrl").

%% API
-export([start_link/4,
         publish/2]).

%% Callbacks
-export([init/1,
         code_change/4,
         handle_event/3,
         handle_info/3,
         handle_sync_event/4,
         terminate/3]).

%% States
-export([prepare/2,
         execute/2,
         waiting/2,
         waiting_n/2,
         finalize/2]).

-record(state, {preflist,
                req_id,
                coordinator,
                from,
                channel,
                message,
                num_responses,
                replies,
                pids}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(ReqId, From, Channel, Message) ->
    gen_fsm:start_link(?MODULE, [ReqId, From, Channel, Message], []).

publish(Channel, Message) ->
    ReqId = riak_pubsub:mk_reqid(),
    riak_pubsub_publish_fsm_sup:start_child(
        [ReqId, self(), Channel, Message]),
    {ok, ReqId}.

%%%===================================================================
%%% Callbacks
%%%===================================================================

handle_info(_Info, _StateName, StateData) ->
    {stop, badmsg, StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop, badmsg, StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop, badmsg, StateData}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.

%%%===================================================================
%%% States
%%%===================================================================

%% @doc Initialize the request.
init([ReqId, From, Channel, Message]) ->
    State = #state{preflist=undefined,
                   req_id=ReqId,
                   coordinator=node(),
                   from=From,
                   channel=Channel,
                   message=Message,
                   num_responses=0,
                   pids=[],
                   replies=[]},
    {ok, prepare, State, 0}.

%% @doc Prepare request by retrieving the preflist.
prepare(timeout, #state{channel=Channel}=State) ->
    DocIdx = riak_core_util:chash_key({<<"subscriptions">>, Channel}),
    Preflist = riak_core_apl:get_primary_apl(DocIdx, ?N,
                                             riak_pubsub_publications),
    Preflist2 = [{Index, Node} || {{Index, Node}, _Type} <- Preflist],
    {next_state, execute, State#state{preflist=Preflist2}, 0}.

%% @doc Execute the request.
execute(timeout, #state{preflist=Preflist,
                        req_id=ReqId,
                        coordinator=Coordinator,
                        channel=Channel,
                        message=Message}=State) ->
    riak_pubsub_publications_vnode:publish(Preflist,
                                           {ReqId, Coordinator},
                                           Channel, Message),
    {next_state, waiting, State}.

%% @doc Pull a unique list of subscriptions from replicas, and
%%      relay the message to it.
waiting({ok, _ReqId, IndexNode, Reply},
        #state{from=From,
               req_id=ReqId,
               message=Message,
               num_responses=NumResponses0,
               replies=Replies0}=State0) ->
    NumResponses = NumResponses0 + 1,
    Replies = [{IndexNode, Reply}|Replies0],
    State = State0#state{num_responses=NumResponses, replies=Replies},

    case NumResponses =:= ?R of
        true ->
            Pids = propagate(Message,
                             riak_dt_orset:value(merge(Replies))),
            From ! {ReqId, ok, Pids},

            case NumResponses =:= ?N of
                true ->
                    {next_state, finalize, State, 0};
                false ->
                    {next_state, waiting_n, State}
            end;
        false ->
            {next_state, waiting, State}
    end.

%% @doc Wait for the remainder of responses from replicas.
waiting_n({ok, _ReqId, IndexNode, Reply},
        #state{num_responses=NumResponses0,
               replies=Replies0}=State0) ->
    NumResponses = NumResponses0 + 1,
    Replies = [{IndexNode, Reply}|Replies0],
    State = State0#state{num_responses=NumResponses, replies=Replies},

    case NumResponses =:= ?N of
        true ->
            {next_state, finalize, State, 0};
        false ->
            {next_state, waiting_n, State}
    end.

%% @doc Perform read repair.
finalize(timeout, #state{replies=Replies}=State) ->
    ok = repair(Replies, State#state{pids=merge(Replies)}),
    {stop, normal, State}.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

%% @doc Perform merge of replicas.
merge(Replies) ->
    lists:foldl(fun({_, Pids}, Acc) -> riak_dt_orset:merge(Pids, Acc) end,
                riak_dt_orset:new(), Replies).

%% @doc Propagate messages to subscribers.
propagate(Message, Pids) when is_list(Pids) ->
    [propagate(Message, Pid) || Pid <- Pids],
    Pids;
propagate(Message, Pid) when is_pid(Pid) ->
    DocIdx = riak_core_util:chash_key({<<"subscriptions">>, Pid}),
    Preflist = riak_core_apl:get_primary_apl(DocIdx, 1, riak_pubsub),
    Preflist2 = [{Index, Node} || {{Index, Node}, _Type} <- Preflist],
    riak_pubsub_message_proxy_vnode:accept(Preflist2, Message, Pid).

%% @doc Trigger repair if necessary.
repair([{IndexNode, Pids}|Replies],
       #state{channel=Channel, pids=MPids}=State) ->
    case riak_dt_orset:equal(Pids, MPids) of
        false ->
            riak_pubsub_subscriptions_vnode:repair(IndexNode, Channel, MPids);
        true ->
            ok
    end,
    repair(Replies, State);
repair([], _State) -> ok.

%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Christopher Meiklejohn.  All Rights Reserved.
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
%% @author Christopher Meiklejohn <christopher.meiklejohn@gmail.com>
%% @copyright 2013 Christopher Meiklejohn.
%% @doc Supervisor for the leave requests.

-module(riak_pg_leave_fsm_sup).
-author('Christopher Meiklejohn <christopher.meiklejohn@gmail.com>').

-behaviour(supervisor).

%% API
-export([start_link/0,
         start_child/1,
         terminate_child/2]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

%% @doc API for starting the supervisor.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a child.
start_child(Args) ->
    supervisor:start_child(?MODULE, Args).

%% @doc Stop a child immediately
terminate_child(Supervisor, Pid) ->
    supervisor:terminate_child(Supervisor, Pid).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

%% @doc supervisor callback.
init([]) ->
    Spec = {riak_pg_leave_fsm,
            {riak_pg_leave_fsm, start_link, []},
             temporary, 5000, worker, [riak_pg_leave_fsm]},

    {ok, {{simple_one_for_one, 10, 10}, [Spec]}}.

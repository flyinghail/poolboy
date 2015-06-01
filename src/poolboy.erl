%% Poolboy - A hunky Erlang worker pool factory

-module(poolboy).
-behaviour(gen_server).

-export([work/2, work/3, work/4,
    checkout/1, checkout/2, checkout/3, checkin/2, transaction/2,
    transaction/3, child_spec/2, child_spec/3, start/1, start/2,
    start_link/1, start_link/2, stop/1, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
-export_type([pool/0]).

-define(TIMEOUT, 5000).

-ifdef(pre17).
-type pid_queue() :: queue().
-else.
-type pid_queue() :: queue:queue().
-endif.

-type pool() ::
    Name :: (atom() | pid()) |
    {Name :: atom(), node()} |
    {local, Name :: atom()} |
    {global, GlobalName :: any()} |
    {via, Module :: atom(), ViaName :: any()}.

% Copied from gen:start_ret/0
-type start_ret() :: {'ok', pid()} | 'ignore' | {'error', term()}.

-record(worker, {
    updated :: erlang:timestamp(),
    pid :: pid()
}).
-type worker_queue() :: queue:queue(#worker{}).

-record(state, {
    supervisor :: pid(),
    workers :: worker_queue(),
    waiting :: pid_queue(),
    monitors :: ets:tid(),
    size = 5 :: non_neg_integer(),
    overflow = 0 :: non_neg_integer(),
    max_overflow = 10 :: non_neg_integer(),
    strategy = lifo :: lifo | fifo
}).

-spec work(Pool :: pool(), Msg :: any()) -> any().
work(Pool, Msg) ->
    work(Pool, Msg, true).

-spec work(Pool :: pool(), Msg :: any(), Block :: boolean()) -> any() | full.
work(Pool, Msg, Block) ->
    work(Pool, Msg, Block, ?TIMEOUT).

-spec work(Pool :: pool(), Msg :: any(), Block :: boolean(), Timeout :: timeout()) -> any() | full.
work(Pool, Msg, Block, Timeout) ->
    call(Pool, {work, Msg}, Block, Timeout).

-spec checkout(Pool :: pool()) -> pid().
checkout(Pool) ->
    checkout(Pool, true).

-spec checkout(Pool :: pool(), Block :: boolean()) -> pid() | full.
checkout(Pool, Block) ->
    checkout(Pool, Block, ?TIMEOUT).

-spec checkout(Pool :: pool(), Block :: boolean(), Timeout :: timeout())
    -> pid() | full.
checkout(Pool, Block, Timeout) ->
    call(Pool, checkout, Block, Timeout).

-spec checkin(Pool :: pool(), Worker :: pid()) -> ok.
checkin(Pool, Worker) when is_pid(Worker) ->
    gen_server:cast(Pool, {checkin, Worker}).

-spec transaction(Pool :: pool(), Fun :: fun((Worker :: pid()) -> any()))
    -> any().
transaction(Pool, Fun) ->
    transaction(Pool, Fun, ?TIMEOUT).

-spec transaction(Pool :: pool(), Fun :: fun((Worker :: pid()) -> any()),
    Timeout :: timeout()) -> any().
transaction(Pool, Fun, Timeout) ->
    Worker = checkout(Pool, true, Timeout),
    try
        Fun(Worker)
    after
        ok = checkin(Pool, Worker)
    end.

-spec child_spec(PoolId :: term(), PoolArgs :: proplists:proplist())
    -> supervisor:child_spec().
child_spec(PoolId, PoolArgs) ->
    child_spec(PoolId, PoolArgs, []).

-spec child_spec(PoolId :: term(),
                 PoolArgs :: proplists:proplist(),
                 WorkerArgs :: proplists:proplist())
    -> supervisor:child_spec().
child_spec(PoolId, PoolArgs, WorkerArgs) ->
    {PoolId, {poolboy, start_link, [PoolArgs, WorkerArgs]},
     permanent, 5000, worker, [poolboy]}.

-spec start(PoolArgs :: proplists:proplist())
    -> start_ret().
start(PoolArgs) ->
    start(PoolArgs, PoolArgs).

-spec start(PoolArgs :: proplists:proplist(),
            WorkerArgs:: proplists:proplist())
    -> start_ret().
start(PoolArgs, WorkerArgs) ->
    start_pool(start, PoolArgs, WorkerArgs).

-spec start_link(PoolArgs :: proplists:proplist())
    -> start_ret().
start_link(PoolArgs)  ->
    %% for backwards compatability, pass the pool args as the worker args as well
    start_link(PoolArgs, PoolArgs).

-spec start_link(PoolArgs :: proplists:proplist(),
                 WorkerArgs:: proplists:proplist())
    -> start_ret().
start_link(PoolArgs, WorkerArgs)  ->
    start_pool(start_link, PoolArgs, WorkerArgs).

-spec stop(Pool :: pool()) -> ok.
stop(Pool) ->
    gen_server:call(Pool, stop).

-spec status(Pool :: pool()) -> {atom(), integer(), integer(), integer()}.
status(Pool) ->
    gen_server:call(Pool, status).

call(Pool, Msg, Block, Timeout) ->
    CRef = make_ref(),
    try
        gen_server:call(Pool, {Msg, CRef, Block}, Timeout)
    catch
        Class:Reason ->
            gen_server:cast(Pool, {cancel_waiting, CRef}),
            erlang:raise(Class, Reason, erlang:get_stacktrace())
    end.

init({PoolArgs, WorkerArgs}) ->
    process_flag(trap_exit, true),
    Waiting = queue:new(),
    Monitors = ets:new(monitors, [private]),
    init(PoolArgs, WorkerArgs, #state{waiting = Waiting, monitors = Monitors}).

init([{worker_module, Mod} | Rest], WorkerArgs, State) when is_atom(Mod) ->
    {ok, Sup} = poolboy_sup:start_link(Mod, WorkerArgs),
    init(Rest, WorkerArgs, State#state{supervisor = Sup});
init([{size, Size} | Rest], WorkerArgs, State) when is_integer(Size) ->
    init(Rest, WorkerArgs, State#state{size = Size});
init([{max_overflow, MaxOverflow} | Rest], WorkerArgs, State) when is_integer(MaxOverflow) ->
    init(Rest, WorkerArgs, State#state{max_overflow = MaxOverflow});
init([{strategy, lifo} | Rest], WorkerArgs, State) ->
    init(Rest, WorkerArgs, State#state{strategy = lifo});
init([{strategy, fifo} | Rest], WorkerArgs, State) ->
    init(Rest, WorkerArgs, State#state{strategy = fifo});
init([_ | Rest], WorkerArgs, State) ->
    init(Rest, WorkerArgs, State);
init([], _WorkerArgs, #state{size = Size, supervisor = Sup} = State) ->
    Workers = prepopulate(Size, Sup),
    {ok, State#state{workers = Workers}}.

handle_cast({checkin, Pid}, State = #state{monitors = Monitors}) ->
    case ets:lookup(Monitors, Pid) of
        [{Pid, _, MRef}] ->
            true = erlang:demonitor(MRef),
            true = ets:delete(Monitors, Pid),
            NewState = handle_checkin(Pid, State),
            {noreply, NewState};
        [] ->
            {noreply, State}
    end;

handle_cast({cancel_waiting, CRef}, State) ->
    case ets:match(State#state.monitors, {'$1', CRef, '$2'}) of
        [[Pid, MRef]] ->
            demonitor(MRef, [flush]),
            true = ets:delete(State#state.monitors, Pid),
            NewState = handle_checkin(Pid, State),
            {noreply, NewState};
        [] ->
            Cancel = fun({_, Ref, MRef}) when Ref =:= CRef ->
                             demonitor(MRef, [flush]),
                             false;
                        (_) ->
                             true
                     end,
            Waiting = queue:filter(Cancel, State#state.waiting),
            {noreply, State#state{waiting = Waiting}}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_call({Do, CRef, Block}, {FromPid, _} = From, State) ->
    #state{supervisor = Sup,
        workers = Workers,
        monitors = Monitors,
        overflow = Overflow,
        max_overflow = MaxOverflow} = State,
    case queue:out(Workers) of
        {{value, Worker}, Left} ->
            MRef = erlang:monitor(process, FromPid),
            true = ets:insert(Monitors, {Worker#worker.pid, CRef, MRef}),
            do(Do, Worker#worker.pid, From, State#state{workers = Left});
        {empty, _} when MaxOverflow > 0 andalso Overflow < MaxOverflow ->
            Worker = new_worker(Sup),
            MRef = erlang:monitor(process, FromPid),
            true = ets:insert(Monitors, {Worker#worker.pid, CRef, MRef}),
            do(Do, Worker#worker.pid, From, State#state{overflow = Overflow + 1});
        {empty, _} when Block =:= false ->
            {reply, full, State};
        {empty, _} ->
            MRef = erlang:monitor(process, FromPid),
            QueueKey = waiting_key(Do, From),
            Waiting = queue:in({QueueKey, CRef, MRef}, State#state.waiting),
            {noreply, State#state{waiting = Waiting}}
    end;

handle_call(status, _From, #state{
    workers = Workers,
    monitors = Monitors,
    overflow = Overflow
} = State) ->
    StateName = state_name(State),
    {reply, {StateName, queue:len(Workers), Overflow, ets:info(Monitors, size)}, State};
handle_call(get_avail_workers, _From, State) ->
    Workers = State#state.workers,
    {reply, Workers, State};
handle_call(get_all_workers, _From, State) ->
    Sup = State#state.supervisor,
    WorkerList = supervisor:which_children(Sup),
    {reply, WorkerList, State};
handle_call(get_all_monitors, _From, State) ->
    Monitors = ets:select(State#state.monitors,
                          [{{'$1', '_', '$2'}, [], [{{'$1', '$2'}}]}]),
    {reply, Monitors, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Msg, _From, State) ->
    Reply = {error, invalid_message},
    {reply, Reply, State}.

handle_info({'DOWN', MRef, _, _, _}, State) ->
    case ets:match(State#state.monitors, {'$1', '_', MRef}) of
        [[Pid]] ->
            true = ets:delete(State#state.monitors, Pid),
            NewState = handle_checkin(Pid, State),
            {noreply, NewState};
        [] ->
            Waiting = queue:filter(fun ({_, _, R}) -> R =/= MRef end, State#state.waiting),
            {noreply, State#state{waiting = Waiting}}
    end;
handle_info({'EXIT', Pid, _Reason}, State) ->
    #state{supervisor = Sup,
           monitors = Monitors} = State,
    case ets:lookup(Monitors, Pid) of
        [{Pid, _, MRef}] ->
            true = erlang:demonitor(MRef),
            true = ets:delete(Monitors, Pid),
            NewState = handle_worker_exit(Pid, State),
            {noreply, NewState};
        [] ->
            case queue:member(Pid, State#state.workers) of
                true ->
                    W = queue:filter(fun (#worker{pid = P}) -> P =/= Pid end, State#state.workers),
                    {noreply, State#state{
                        workers = queue:in_r(
                            new_worker(Sup), W
                        )
                    }};
                false ->
                    {noreply, State}
            end
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    {[], []} = queue:filter(fun(W) -> unlink(W#worker.pid), false end, State#state.workers),
    true = exit(State#state.supervisor, shutdown),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

start_pool(StartFun, PoolArgs, WorkerArgs) ->
    case proplists:get_value(name, PoolArgs) of
        undefined ->
            gen_server:StartFun(?MODULE, {PoolArgs, WorkerArgs}, []);
        Name ->
            gen_server:StartFun(Name, ?MODULE, {PoolArgs, WorkerArgs}, [])
    end.

new_worker(Sup) ->
    new_worker(Sup,
        os:timestamp()
    ).

new_worker(Sup, Now) ->
    {ok, Pid} = supervisor:start_child(Sup, []),
    true = link(Pid),
    #worker{
        pid = Pid,
        updated = Now
    }.

dismiss_worker(Sup, Pid) ->
    true = unlink(Pid),
    supervisor:terminate_child(Sup, Pid).

prepopulate(N, _Sup) when N < 1 ->
    queue:new();
prepopulate(N, Sup) ->
    prepopulate(N, Sup,
        os:timestamp(),
        queue:new()
    ).

prepopulate(0, _Sup, _Now, Workers) ->
    Workers;
prepopulate(N, Sup, Now, Workers) ->
    prepopulate(N - 1, Sup, Now,
        queue:in(Workers,
            new_worker(Sup, Now)
        )
    ).

handle_checkin(Pid, #state{
    supervisor = Sup,
    waiting = Waiting,
    monitors = Monitors,
    overflow = Overflow,
    strategy = Strategy
} = State) ->
    case queue:out(Waiting) of
        {{value, {{work, Msg, From}, CRef, MRef}}, Left} ->
            true = ets:insert(Monitors, {Pid, CRef, MRef}),
            send_to_worker(Pid, Msg, From),
            State#state{waiting = Left};
        {{value, {From, CRef, MRef}}, Left} ->
            true = ets:insert(Monitors, {Pid, CRef, MRef}),
            gen_server:reply(From, Pid),
            State#state{waiting = Left};
        {empty, _} when Overflow > 0 ->
            ok = dismiss_worker(Sup, Pid),
            State#state{overflow = Overflow - 1};
        {empty, _} ->
            Workers =
                case Strategy of
                    lifo -> queue:in_r(Pid, State#state.workers);
                    fifo -> queue:in(Pid, State#state.workers)
                end,
            State#state{workers = Workers, overflow = 0}
    end.

handle_worker_exit(Pid, State) ->
    #state{supervisor = Sup,
        monitors = Monitors,
        overflow = Overflow} = State,
    case queue:out(State#state.waiting) of
        {{value, {{work, Msg, From}, CRef, MRef}}, LeftWaiting} ->
            NewWorker = new_worker(State#state.supervisor),
            true = ets:insert(Monitors, {NewWorker, CRef, MRef}),
            send_to_worker(NewWorker, Msg, From),
            State#state{waiting = LeftWaiting};
        {{value, {From, CRef, MRef}}, LeftWaiting} ->
            NewWorker = new_worker(State#state.supervisor),
            true = ets:insert(Monitors, {NewWorker, CRef, MRef}),
            gen_server:reply(From, NewWorker),
            State#state{waiting = LeftWaiting};
        {empty, Empty} when Overflow > 0 ->
            State#state{overflow = Overflow - 1, waiting = Empty};
        {empty, Empty} ->
            Workers =
                queue:in(
                    new_worker(Sup),
                    queue:filter(fun (#worker{pid = P}) -> P =/= Pid end, State#state.workers)
                ),
            State#state{workers = Workers, waiting = Empty}
    end.

state_name(#state{
    overflow = Overflow,
    max_overflow = MaxOverflow,
    workers = Workers
}) when Overflow < 1 ->
    case queue:len(Workers) of
        0 when MaxOverflow < 1 -> full;
        0 -> overflow;
        _ -> ready
    end;
state_name(#state{overflow = MaxOverflow, max_overflow = MaxOverflow}) ->
    full;
state_name(_State) ->
    overflow.

send_to_worker(Worker, Msg, From) ->
    Self = self(),
    gen_server:cast(Worker, {fromPool, Msg, fun (Reply) ->
        gen_server:reply(From, Reply),
        gen_server:cast(Self, {checkin, Worker})
    end}).

do(checkout, Pid, _From, State) ->
    {reply, Pid, State};
do({work, Msg}, Pid, From, State) ->
    send_to_worker(Pid, Msg, From),
    {noreply, State}.

waiting_key(checkout, From) ->
    From;
waiting_key({work, Msg}, From) ->
    {work, Msg, From}.

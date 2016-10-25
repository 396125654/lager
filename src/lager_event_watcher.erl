%%%-------------------------------------------------------------------
%%% @author clanchun <clanchun@gmail.com>
%%% @copyright (C) 2016, clanchun
%%% @doc
%%%
%%% @end
%%% Created : 20 Sep 2016 by clanchun <clanchun@gmail.com>
%%%-------------------------------------------------------------------
-module(lager_event_watcher).

-include("lager.hrl").

-compile([{parse_transform, lager_transform}]).

-behaviour(gen_server).

%% API
-export([start_link/4]).

-export([get_state/0,
         set/1,
         set/2
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
          threshold        :: non_neg_integer(),
          interval         :: non_neg_integer(),
          marks            :: [non_neg_integer()],
          reboot_after     :: non_neg_integer()
         }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Threshold, Interval, MarksLen, RebootAfter) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE,
                          [Threshold, Interval, MarksLen, RebootAfter], []).

get_state() ->
    gen_server:call(?SERVER, get_state).

set(KVs) ->
    [set(K, V) || {K, V} <- KVs].

-spec set(threshold | interval | marks_len | rebbot_after, term()) -> {ok, term()}.

set(Key, Value) ->
    gen_server:call(?SERVER, {Key, Value}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Threshold, Interval, MarksLen, RebootAfter]) ->
    erlang:send_after(Interval, self(), check),
    {ok, #state{threshold = Threshold,
                interval = Interval,
                marks = lists:duplicate(MarksLen, 0),
                reboot_after = RebootAfter
               }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call({threshold, NewThreshold}, _From, 
            #state{threshold = OldThreshold} = State) ->
    {reply, {ok, OldThreshold, NewThreshold}, State#state{threshold = NewThreshold}};
handle_call({interval, NewInterval}, _From, 
            #state{interval = OldInterval} = State) ->
    {reply, {ok, OldInterval, NewInterval}, State#state{interval = NewInterval}};
handle_call({marks_len, NewMarksLen}, _From, 
            #state{marks = OldMarks} = State) ->
    NewMarks = lists:duplicate(NewMarksLen, 0),
    {reply, {ok, OldMarks, NewMarks}, State#state{marks = NewMarks}};
handle_call({reboot_after, NewRebootAfter}, _From, 
            #state{reboot_after = OldRebootAfter} = State) ->
    {reply, {ok, OldRebootAfter, NewRebootAfter}, State#state{reboot_after = NewRebootAfter}};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(check, #state{threshold = Threshold,
                          interval = Interval,
                          marks = Marks,
                          reboot_after = RebootAfter
                         } = State) ->
    try process_info(whereis(lager_event), message_queue_len) of
        {message_queue_len, QLen} ->
            case check(QLen, Threshold, Marks) of
                {kill, NewMarks} ->
                    exit(whereis(lager_event), kill),
                    error_logger:error_msg("lager event got killed~n"),
                    erlang:send_after(RebootAfter, self(), reboot),
                    {noreply, State#state{marks = NewMarks}};
                NewMarks ->
                    erlang:send_after(Interval, self(), check),
                    {noreply, State#state{marks = NewMarks}}
            end
    catch
        _C:_R ->
            erlang:send_after(Interval, self(), check),
            {noreply, State}
    end;

handle_info(reboot, #state{interval = Interval} = State) ->
    lager_app:boot(),
    lager:critical("lager event handlers rebooted"),
    erlang:send_after(Interval, self(), check),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

check(QLen, Threshold, Marks) when QLen < Threshold ->
    lists:duplicate(length(Marks), 0);
check(_, _, Marks) ->
    MarksLen = length(Marks),
    case count(1, Marks) of
        Len when Len == MarksLen - 1 ->
            {kill, lists:duplicate(MarksLen, 0)};
        Len ->
            lists:duplicate(Len + 1, 1) ++ lists:duplicate(MarksLen - Len - 1, 0)
    end.

count(_, []) ->
    0;
count(What, [What | T]) ->
    1 + count(What, T);
count(What, [_ | T]) ->
    count(What, T).

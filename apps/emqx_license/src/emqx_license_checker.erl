%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_license_checker).

-include("emqx_license.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-behaviour(gen_server).

-define(CHECK_INTERVAL, timer:seconds(5)).
-define(REFRESH_INTERVAL, timer:minutes(2)).
-define(EXPIRY_ALARM_CHECK_INTERVAL, timer:hours(24)).

-define(OK(EXPR),
    try
        _ = begin
            EXPR
        end,
        ok
    catch
        _:_ -> ok
    end
).

-export([
    start_link/1,
    start_link/2,
    update/1,
    dump/0,
    expiry_epoch/0,
    purge/0,
    limits/0,
    print_warnings/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-define(LICENSE_TAB, emqx_license).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

-type limits() :: #{max_connections := non_neg_integer() | ?ERR_EXPIRED}.

-spec start_link(emqx_license_parser:license()) -> {ok, pid()}.
start_link(LicenseFetcher) ->
    start_link(LicenseFetcher, ?CHECK_INTERVAL).

-spec start_link(emqx_license_parser:license(), timeout()) -> {ok, pid()}.
start_link(LicenseFetcher, CheckInterval) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [LicenseFetcher, CheckInterval], []).

-spec update(emqx_license_parser:license()) -> map().
update(License) ->
    gen_server:call(?MODULE, {update, License}, infinity).

-spec dump() -> [{atom(), term()}].
dump() ->
    gen_server:call(?MODULE, dump, infinity).

-spec expiry_epoch() -> integer().
expiry_epoch() ->
    gen_server:call(?MODULE, expiry_epoch, infinity).

-spec limits() -> {ok, limits()} | {error, any()}.
limits() ->
    try ets:lookup(?LICENSE_TAB, limits) of
        [{limits, Limits}] -> {ok, Limits};
        _ -> {error, no_license}
    catch
        error:badarg ->
            {error, no_license}
    end.

%% @doc Force purge the license table.
-spec purge() -> ok.
purge() ->
    gen_server:call(?MODULE, purge, infinity).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([LicenseFetcher, CheckInterval]) ->
    case LicenseFetcher() of
        {ok, License} ->
            ?LICENSE_TAB = ets:new(?LICENSE_TAB, [
                set, protected, named_table, {read_concurrency, true}
            ]),
            ok = print_warnings(check_license(License)),
            State0 = ensure_check_license_timer(#{
                check_license_interval => CheckInterval,
                license => License
            }),
            State1 = ensure_refresh_timer(State0),
            State = ensure_check_expiry_timer(State1),
            {ok, State};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({update, License}, _From, #{license := Old} = State) ->
    ok = expiry_early_alarm(License),
    State1 = ensure_refresh_timer(State),
    ok = log_new_license(Old, License),
    {reply, check_license(License), State1#{license => License}};
handle_call(dump, _From, #{license := License} = State) ->
    {reply, emqx_license_parser:dump(License), State};
handle_call(expiry_epoch, _From, #{license := License} = State) ->
    ExpiryEpoch = date_to_expiry_epoch(emqx_license_parser:expiry_date(License)),
    {reply, ExpiryEpoch, State};
handle_call(purge, _From, State) ->
    _ = ets:delete_all_objects(?LICENSE_TAB),
    {reply, ok, State};
handle_call(_Req, _From, State) ->
    {reply, unknown, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check_license, #{license := License} = State) ->
    #{} = check_license(License),
    NewState = ensure_check_license_timer(State),
    ?tp(emqx_license_checked, #{}),
    {noreply, NewState};
handle_info(check_expiry_alarm, #{license := License} = State) ->
    ok = expiry_early_alarm(License),
    NewState = ensure_check_expiry_timer(State),
    {noreply, NewState};
handle_info(refresh, State0) ->
    State1 = refresh(State0),
    NewState = ensure_refresh_timer(State1),
    {noreply, NewState};
handle_info(_Msg, State) ->
    {noreply, State}.

%%------------------------------------------------------------------------------
%% Private functions
%%------------------------------------------------------------------------------

refresh(#{license := #{source := <<"file://", _/binary>> = Source} = License} = State) ->
    case emqx_license_parser:parse(Source) of
        {ok, License} ->
            ?tp(emqx_license_refresh_no_change, #{}),
            %% no change
            State;
        {ok, NewLicense} ->
            ok = log_new_license(License, NewLicense),
            %% ensure alarm is set or cleared
            ok = expiry_early_alarm(NewLicense),
            ?tp(emqx_license_refresh_changed, #{new_license => NewLicense}),
            State#{license => NewLicense};
        {error, Reason} ->
            ?tp(
                error,
                emqx_license_refresh_failed,
                Reason#{continue_with_license => emqx_license_parser:summary(License)}
            ),
            State
    end;
refresh(State) ->
    State.

log_new_license(Old, New) ->
    ?SLOG(info, #{
        msg => "new_license_loaded",
        old_license => emqx_license_parser:summary(Old),
        new_license => emqx_license_parser:summary(New)
    }).

ensure_check_license_timer(#{check_license_interval := CheckInterval} = State) ->
    ok = cancel_timer(State, check_timer),
    State#{check_timer => erlang:send_after(CheckInterval, self(), check_license)}.

ensure_check_expiry_timer(State) ->
    ok = cancel_timer(State, expiry_alarm_timer),
    Ref = erlang:send_after(?EXPIRY_ALARM_CHECK_INTERVAL, self(), check_expiry_alarm),
    State#{expiry_alarm_timer => Ref}.

%% refresh is to work with file:// license keys.
ensure_refresh_timer(State) ->
    ok = cancel_timer(State, refresh_timer),
    Ref = erlang:send_after(?REFRESH_INTERVAL, self(), refresh),
    State#{refresh_timer => Ref}.

cancel_timer(State, Key) ->
    case maps:find(Key, State) of
        {ok, Ref} when is_reference(Ref) ->
            _ = erlang:cancel_timer(Ref),
            ok;
        _ ->
            ok
    end.

check_license(License) ->
    DaysLeft = days_left(License),
    IsOverdue = is_overdue(License, DaysLeft),
    NeedRestriction = IsOverdue,
    MaxConn = emqx_license_parser:max_connections(License),
    Limits = limits(License, NeedRestriction),
    true = apply_limits(Limits),
    #{
        warn_evaluation => warn_evaluation(License, NeedRestriction, MaxConn),
        warn_expiry => {(DaysLeft < 0), -DaysLeft}
    }.

warn_evaluation(License, false, MaxConn) ->
    {emqx_license_parser:customer_type(License) == ?EVALUATION_CUSTOMER, MaxConn};
warn_evaluation(_License, _NeedRestrict, _Limits) ->
    false.

limits(License, false) -> #{max_connections => emqx_license_parser:max_connections(License)};
limits(_License, true) -> #{max_connections => ?ERR_EXPIRED}.

days_left(License) ->
    DateEnd = emqx_license_parser:expiry_date(License),
    {DateNow, _} = calendar:universal_time(),
    calendar:date_to_gregorian_days(DateEnd) - calendar:date_to_gregorian_days(DateNow).

is_overdue(License, DaysLeft) ->
    CType = emqx_license_parser:customer_type(License),
    Type = emqx_license_parser:license_type(License),

    small_customer_overdue(CType, DaysLeft) orelse
        non_official_license_overdue(Type, DaysLeft).

%% small customers overdue 90 days after license expiry date
small_customer_overdue(?SMALL_CUSTOMER, DaysLeft) -> DaysLeft < ?EXPIRED_DAY;
small_customer_overdue(_CType, _DaysLeft) -> false.

%% never restrict official license
non_official_license_overdue(?OFFICIAL, _) -> false;
non_official_license_overdue(_, DaysLeft) -> DaysLeft < 0.

%% 62167219200 =:= calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).
-define(EPOCH_START, 62167219200).
-spec date_to_expiry_epoch(calendar:date()) -> Seconds :: non_neg_integer().
date_to_expiry_epoch({Y, M, D}) ->
    calendar:datetime_to_gregorian_seconds({{Y, M, D}, {0, 0, 0}}) - ?EPOCH_START.

apply_limits(Limits) ->
    ets:insert(?LICENSE_TAB, {limits, Limits}).

expiry_early_alarm(License) ->
    case days_left(License) < 30 of
        true ->
            {Y, M, D} = emqx_license_parser:expiry_date(License),
            Date = iolist_to_binary(io_lib:format("~B~2..0B~2..0B", [Y, M, D])),
            ?OK(emqx_alarm:activate(license_expiry, #{expiry_at => Date}));
        false ->
            ?OK(emqx_alarm:ensure_deactivated(license_expiry))
    end.

print_warnings(Warnings) ->
    ok = print_evaluation_warning(Warnings),
    ok = print_expiry_warning(Warnings).

print_evaluation_warning(#{warn_evaluation := {true, MaxConn}}) ->
    io:format(?EVALUATION_LOG, [MaxConn]);
print_evaluation_warning(_) ->
    ok.

print_expiry_warning(#{warn_expiry := {true, Days}}) ->
    io:format(?EXPIRY_LOG, [Days]);
print_expiry_warning(_) ->
    ok.

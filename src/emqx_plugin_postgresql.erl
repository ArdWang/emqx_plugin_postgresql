-module(emqx_plugin_postgresql).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_hooks.hrl").
-include_lib("emqx/include/logger.hrl").
-include("emqx_plugin_postgresql.hrl").

-export([
  load/0
  , unload/0
  , reload/0
]).

-export([on_message_publish/1]).
-export([on_client_connected/3]).
-export([on_client_disconnected/4]).

%%--------------------------------------------------------------------
%% Application lifecycle
%%--------------------------------------------------------------------

load() ->
  ensure_ets_table(),
  load(read_config()).

load(#{connection := Connection, topics := Topics}) ->
  case start_resource(Connection) of
    {ok, _} ->
      topic_parse(Topics),
      hook('message.publish', {?MODULE, on_message_publish, []}),
      hook('client.connected', {?MODULE, on_client_connected, []}),
      hook('client.disconnected', {?MODULE, on_client_disconnected, []}),
      ok;
    {error, Reason} ->
      {error, Reason}
  end;
load(_) ->
  {error, "config_error"}.

unload() ->
  unhook('message.publish', {?MODULE, on_message_publish}),
  unhook('client.connected', {?MODULE, on_client_connected}),
  unhook('client.disconnected', {?MODULE, on_client_disconnected}),
  catch ets:delete(?PLUGIN_POSTGRESQL_TAB),
  emqx_resource:remove_local(?PLUGIN_POSTGRESQL_RESOURCE_ID).

reload() ->
  ets:delete_all_objects(?PLUGIN_POSTGRESQL_TAB),
  emqx_resource:stop(?PLUGIN_POSTGRESQL_RESOURCE_ID),
  emqx_resource:remove_local(?PLUGIN_POSTGRESQL_RESOURCE_ID),
  load(read_config()).

%%--------------------------------------------------------------------
%% Hook: message.publish
%%--------------------------------------------------------------------

on_message_publish(Message = #message{topic = Topic}) ->
  case select(Message) of
    {true, Tables} when Tables =/= [] ->
      ?SLOG(debug, #{
        msg => "Matched queries",
        topic => Topic,
        tables => Tables
      }),
      spawn(fun() ->
        try
          handle_matched_message(Message, Topic, Tables)
        catch
          Error:Reason ->
            ?SLOG(error, #{
              msg => "async_postgresql_query_failed",
              error => Error,
              reason => Reason,
              message => Message
            })
        end
      end);
    {true, []} ->
      ok;
    false ->
      ok
  end,
  {ok, Message}.

%%--------------------------------------------------------------------
%% Hook: client.connected
%%--------------------------------------------------------------------

on_client_connected(#{clientid := ClientId}, _ConnInfo, _State) ->
  spawn(fun() ->
    try
      handle_client_event(ClientId, <<"connected">>)
    catch
      Error:Reason ->
        ?SLOG(error, #{
          msg => "async_postgresql_client_connected_failed",
          clientid => ClientId,
          error => Error,
          reason => Reason
        })
    end
  end),
  {ok}.

%%--------------------------------------------------------------------
%% Hook: client.disconnected
%%--------------------------------------------------------------------

on_client_disconnected(#{clientid := ClientId}, _Reason, _ConnInfo, _State) ->
  spawn(fun() ->
    try
      handle_client_event(ClientId, <<"disconnected">>)
    catch
      Error:Reason ->
        ?SLOG(error, #{
          msg => "async_postgresql_client_disconnected_failed",
          clientid => ClientId,
          error => Error,
          reason => Reason
        })
    end
  end),
  ok.

%%--------------------------------------------------------------------
%% Message handling
%%--------------------------------------------------------------------

handle_matched_message(Message, Topic, Tables) ->
  case binary:match(Topic, <<"device/telemetry/">>) of
    {0, _} ->
      TelemetryData = parse_telemetry_payload(Message),
      SqlList = build_telemetry_sqls(Tables, TelemetryData),
      query(SqlList);
    _ ->
      case binary:match(Topic, <<"device/status/">>) of
        {0, _} ->
          StatusData = parse_status_payload(Message),
          SqlList = build_status_sqls(Tables, StatusData),
          query(SqlList);
        _ ->
          ok
      end
  end.

handle_client_event(ClientId, Event) ->
  SqlList = build_client_event_sqls(ClientId, Event),
  case SqlList of
    [] -> ok;
    _ -> query(SqlList)
  end.

%%--------------------------------------------------------------------
%% Payload parsing
%%--------------------------------------------------------------------

parse_telemetry_payload(Message = #message{payload = Payload, timestamp = Timestamp}) ->
  try
    JsonData = jsx:decode(Payload, [return_maps]),
    Name = maps:get(<<"name">>, JsonData, <<"unknown">>),
    Ct = maps:get(<<"ct">>, JsonData, 0.0),
    Ch = maps:get(<<"ch">>, JsonData, 0.0),
    Ctc = maps:get(<<"ctc">>, JsonData, 0.0),
    Chc = maps:get(<<"chc">>, JsonData, 0.0),
    Time = maps:get(<<"time">>, JsonData, Timestamp),
    #{
      <<"name">> => Name,
      <<"ct">> => Ct,
      <<"ch">> => Ch,
      <<"ctc">> => Ctc,
      <<"chc">> => Chc,
      <<"time">> => Time
    }
  catch
    _:_ ->
      #{
        <<"name">> => <<"unknown">>,
        <<"ct">> => 0.0,
        <<"ch">> => 0.0,
        <<"ctc">> => 0.0,
        <<"chc">> => 0.0,
        <<"time">> => Timestamp
      }
  end.

parse_status_payload(Message = #message{payload = Payload, topic = Topic, timestamp = Timestamp}) ->
  Name = extract_device_name_from_topic(Topic),
  try
    JsonData = jsx:decode(Payload, [return_maps]),
    Version = maps:get(<<"version">>, JsonData, <<"unknown">>),
    SensorTime = maps:get(<<"sensor_time">>, JsonData, Timestamp),
    #{
      <<"name">> => Name,
      <<"version">> => Version,
      <<"sensor_time">> => SensorTime
    }
  catch
    _:_ ->
      #{
        <<"name">> => Name,
        <<"version">> => <<"unknown">>,
        <<"sensor_time">> => Timestamp
      }
  end.

extract_device_name_from_topic(Topic) ->
  Parts = binary:split(Topic, <<"/">>, [global]),
  case length(Parts) of
    Length when Length >= 3 ->
      lists:nth(3, Parts);
    _ ->
      <<"unknown">>
  end.

%%--------------------------------------------------------------------
%% SQL building
%%--------------------------------------------------------------------

build_telemetry_sqls(Tables, #{
  <<"name">> := Name,
  <<"ct">> := Ct,
  <<"ch">> := Ch,
  <<"ctc">> := Ctc,
  <<"chc">> := Chc,
  <<"time">> := Time
}) ->
  NameStr = escape_string(Name),
  TimeSec = safe_div(Time, 1000),
  lists:map(fun(_Table) ->
    Sql = io_lib:format(
      "INSERT INTO sensor_data (name, ct, ch, ctc, chc, sensor_time) "
      "VALUES ('~s', ~s, ~s, ~s, ~s, TO_TIMESTAMP(~s));",
      [NameStr, erlang:float_to_list(Ct), erlang:float_to_list(Ch), erlang:float_to_list(Ctc), erlang:float_to_list(Chc), integer_to_list(TimeSec)]
    ),
    unicode:characters_to_list(Sql)
  end, Tables).

build_status_sqls(Tables, #{
  <<"name">> := Name,
  <<"version">> := Version,
  <<"sensor_time">> := SensorTime
}) ->
  NameStr = escape_string(Name),
  VersionStr = escape_string(Version),
  SensorTimeInt = safe_integer(SensorTime),
  lists:map(fun(_Table) ->
    Sql = io_lib:format(
      "INSERT INTO sensor_status (name, version, sensor_time) "
      "VALUES ('~s', '~s', TO_TIMESTAMP((~s :: bigint)/1000)) "
      "ON CONFLICT (name) "
      "DO UPDATE SET version = EXCLUDED.version, sensor_time = EXCLUDED.sensor_time;",
      [NameStr, VersionStr, integer_to_list(SensorTimeInt)]
    ),
    unicode:characters_to_list(Sql)
  end, Tables).

build_client_event_sqls(ClientId, Event) ->
  AllTables = get_all_tables(),
  case AllTables of
    [] -> [];
    _ ->
      ClientIdStr = escape_string(ClientId),
      EventStr = escape_string(Event),
      NowMs = erlang:system_time(millisecond),
      lists:map(fun(_Table) ->
        Sql = io_lib:format(
          "INSERT INTO sensor_status (name, version, sensor_time) "
          "VALUES ('~s', '~s', TO_TIMESTAMP((~s :: bigint)/1000)) "
          "ON CONFLICT (name) "
          "DO UPDATE SET version = EXCLUDED.version, sensor_time = EXCLUDED.sensor_time;",
          [ClientIdStr, EventStr, integer_to_list(NowMs)]
        ),
        unicode:characters_to_list(Sql)
      end, AllTables)
  end.

get_all_tables() ->
  %% Get all configured table names from ETS
  case catch ets:tab2list(?PLUGIN_POSTGRESQL_TAB) of
    {'EXIT', _} -> [];
    List ->
      %% Extract unique table names
      lists:usort([Table || {_Name, _Filter, Table} <- List])
  end.

%%--------------------------------------------------------------------
%% ETS and topic matching
%%--------------------------------------------------------------------

ensure_ets_table() ->
  case ets:info(?PLUGIN_POSTGRESQL_TAB) of
    undefined ->
      ets:new(?PLUGIN_POSTGRESQL_TAB, [named_table, public, set, {keypos, 1}, {read_concurrency, true}]);
    _ ->
      ets:delete_all_objects(?PLUGIN_POSTGRESQL_TAB)
  end.

topic_parse([]) ->
  ok;
topic_parse([#{filter := Filter, name := Name, table := Table} | T]) ->
  Item = {Name, Filter, Table},
  ets:insert(?PLUGIN_POSTGRESQL_TAB, Item),
  topic_parse(T);
topic_parse([_ | T]) ->
  topic_parse(T).

select(Message) ->
  select(ets:tab2list(?PLUGIN_POSTGRESQL_TAB), Message, []).

select([], _, Acc) ->
  {true, Acc};
select([{Name, Filter, Table} | T], Message, Acc) ->
  case match_topic(Message, Filter) of
    true ->
      select(T, Message, [{Name, Table} | Acc]);
    false ->
      select(T, Message, Acc)
  end.

match_topic(_, <<$#, _/binary>>) ->
  false;
match_topic(_, <<$+, _/binary>>) ->
  false;
match_topic(#message{topic = <<"$SYS/", _/binary>>}, _) ->
  false;
match_topic(#message{topic = Topic}, Filter) ->
  emqx_topic:match(Topic, Filter);
match_topic(_, _) ->
  false.

%%--------------------------------------------------------------------
%% Resource management
%%--------------------------------------------------------------------

start_resource(Connection = #{health_check_interval := HealthCheckInterval}) ->
  ResId = ?PLUGIN_POSTGRESQL_RESOURCE_ID,
  ok = emqx_resource:create_metrics(ResId),
  Result = emqx_resource:create_local(
    ResId,
    ?PLUGIN_POSTGRESQL_RESOURCE_GROUP,
    emqx_plugin_postgresql_connector,
    Connection,
    #{health_check_interval => HealthCheckInterval}),
  start_resource_if_enabled(Result).

start_resource_if_enabled({ok, _Result = #{error := undefined, id := ResId}}) ->
  {ok, ResId};
start_resource_if_enabled({ok, #{error := Error, id := ResId}}) ->
  ?SLOG(error, #{
    msg => "start resource error",
    error => Error,
    resource_id => ResId
  }),
  emqx_resource:stop(ResId),
  {error, Error};
start_resource_if_enabled({error, Reason}) ->
  {error, Reason};

query(SqlList) ->
  query_ret(
    emqx_resource:query(?PLUGIN_POSTGRESQL_RESOURCE_ID, {SqlList, #{}}),
    SqlList
  ).

query_ret({_, ok}, _) ->
  ok;
query_ret(Ret, SqlList) ->
  ?SLOG(error,
    #{
      msg => "failed_to_query_postgresql_resource",
      ret => Ret,
      sql_list => SqlList
    }).

%%--------------------------------------------------------------------
%% Config reading
%%--------------------------------------------------------------------

read_config() ->
  case hocon:load(postgresql_config_file()) of
    {ok, RawConf} ->
      case emqx_config:check_config(emqx_plugin_postgresql_schema, RawConf) of
        {_, #{plugin_postgresql := Conf}} ->
          ?SLOG(info, #{
            msg => "emqx_plugin_postgresql config",
            config => Conf
          }),
          Conf;
        _ ->
          ?SLOG(error, #{
            msg => "bad_hocon_file",
            file => postgresql_config_file()
          }),
          {error, bad_hocon_file}

      end;
    {error, Error} ->
      ?SLOG(error, #{
        msg => "bad_hocon_file",
        file => postgresql_config_file(),
        reason => Error
      }),
      {error, bad_hocon_file}
  end.

postgresql_config_file() ->
  Env = os:getenv("EMQX_PLUGIN_POSTGRESQL_CONF"),
  case Env =:= "" orelse Env =:= false of
    true -> "etc/emqx_plugin_postgresql.hocon";
    false -> Env
  end.

%%--------------------------------------------------------------------
%% Hook helpers
%%--------------------------------------------------------------------

hook(HookPoint, MFA) ->
  emqx_hooks:add(HookPoint, MFA, _Property = ?HP_HIGHEST).

unhook(HookPoint, MFA) ->
  emqx_hooks:del(HookPoint, MFA).

%%--------------------------------------------------------------------
%% Utility functions
%%--------------------------------------------------------------------

escape_string(Bin) when is_binary(Bin) ->
  binary_to_list(replace_single_quotes(Bin));
escape_string(Str) when is_list(Str) ->
  replace_single_quotes(list_to_binary(Str)).

replace_single_quotes(Bin) ->
  binary:replace(Bin, <<"'">>, <<"''">>, [global]).

float_to_list(F) when is_float(F) ->
  io_lib:format("~w", [F]);
float_to_list(I) when is_integer(I) ->
  integer_to_list(I).

safe_div(Timestamp, Divisor) when is_integer(Timestamp) ->
  %% If timestamp is already in seconds (< 10^10), return as-is
  %% If in milliseconds, divide
  case Timestamp > 10000000000 of
    true -> Timestamp div Divisor;
    false -> Timestamp
  end;
safe_div(Timestamp, _) ->
  Timestamp.

safe_integer(T) when is_integer(T) -> T;
safe_integer(T) when is_float(T) -> trunc(T);
safe_integer(_) -> 0.

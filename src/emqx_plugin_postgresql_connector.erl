-module(emqx_plugin_postgresql_connector).

-behaviour(emqx_resource).

-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("emqx/include/logger.hrl").

-export([
    query_mode/1
    , callback_mode/0
    , on_start/2
    , on_get_status/2
    , on_stop/2
    , on_query_async/4
]).

query_mode(_) ->
    simple_async_internal_buffer.

callback_mode() ->
    async_if_possible.

on_start(
    _InstId,
    Connection
) ->
    #{server := Server, database := Database} = Connection,
    Username = maps:get(username, Connection, <<>>),
    Password = maps:get(password, Connection, <<>>),
    PoolSize = maps:get(pool_size, Connection, 8),

    SslOpts =
        case maps:get(ssl, Connection, nil) of
            #{enable := false} ->
                [];
            SSL ->
                [{ssl, emqx_tls_lib:to_client_opts(SSL)}]
        end,

    [Host, PortStr] = case binary:split(Server, <<":">>) of
        [H] -> [H, <<"5432">>];
        [H, P] -> [H, P]
    end,
    Port = binary_to_integer(PortStr),

    Opts = [
        {host, binary_to_list(Host)},
        {port, Port},
        {username, binary_to_list(Username)},
        {password, password_to_list(Password)},
        {database, binary_to_list(Database)}
    ] ++ SslOpts,

    case start_pool(PoolSize, Opts) of
        {ok, PoolPid} ->
            {ok, #{pool_pid => PoolPid, opts => Opts}};
        {error, Reason} ->
            ?SLOG(error, #{
                msg => failed_to_start_postgresql_client,
                reason => Reason
            }),
            {error, Reason}
    end.

on_get_status(
    _InstId,
    #{pool_pid := PoolPid} = State
) ->
    case check_connectivity(PoolPid) of
        ok ->
            ?status_connected;
        {error, Error} ->
            {?status_disconnected, State, Error}
    end.

on_stop(_InstId, #{pool_pid := PoolPid}) ->
    ?SLOG(info, #{
        msg => "postgresql_client_on_stop",
        pool_pid => PoolPid
    }),
    stop_pool(PoolPid),
    ok.

on_query_async(
    InstId,
    {Queries, Message},
    _,
    #{pool_pid := PoolPid} = _ConnectorState
) ->
    try
        do_send_msg(PoolPid, Queries, Message)
    catch
        Error:Reason:Stack ->
            ?SLOG(error, #{
                msg => "emqx_plugin_postgresql_producer on_query_async error",
                error => Error,
                instId => InstId,
                reason => Reason,
                stack => Stack
            }),
            {error, {Error, Reason}}
    end.

%% Pool management using epgsql directly
start_pool(PoolSize, Opts) ->
    case start_worker(Opts) of
        {ok, Conn} ->
            %% For a simple pool, just start one connection
            {ok, #{conn => Conn}};
        {error, Reason} ->
            {error, Reason}
    end.

start_worker(Opts) ->
    case epgsql:connect(Opts) of
        {ok, Conn} ->
            {ok, Conn};
        {error, Reason} ->
            {error, Reason}
    end.

stop_pool(#{conn := Conn}) ->
    catch epgsql:close(Conn),
    ok;
stop_pool(_) ->
    ok.

check_connectivity(#{conn := Conn}) ->
    try epgsql:squery(Conn, "SELECT 1") of
        {ok, _, _} ->
            ok;
        {error, Reason} ->
            ?SLOG(warning, #{
                msg => "postgresql_connection_get_status_error",
                reason => Reason
            }),
            {error, Reason}
    catch
        Class:Error ->
            ?SLOG(warning, #{
                msg => "postgresql_connection_get_status_exception",
                class => Class,
                error => Error
            }),
            {error, {Class, Error}}
    end.

password_to_list(#{raw := Pwd}) -> password_to_list(Pwd);
password_to_list(#{password := Pwd}) -> password_to_list(Pwd);
password_to_list(Pwd) when is_binary(Pwd) -> binary_to_list(Pwd);
password_to_list(Pwd) when is_list(Pwd) -> Pwd;
password_to_list(_) -> "".

do_send_msg(PoolPid, Queries, Message) ->
    #{conn := Conn} = PoolPid,
    lists:foreach(
        fun(Sql) ->
            case epgsql:squery(Conn, Sql) of
                {ok, _, _} ->
                    ok;
                {error, Reason} ->
                    ?SLOG(error, #{
                        msg => "postgresql_query_error",
                        sql => Sql,
                        reason => Reason
                    });
                {error, Class, Reason} ->
                    ?SLOG(error, #{
                        msg => "postgresql_query_error",
                        sql => Sql,
                        class => Class,
                        reason => Reason
                    })
            end
        end,
        Queries
    ).

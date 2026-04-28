-module(emqx_plugin_postgresql_schema).

-include_lib("hocon/include/hoconsc.hrl").

-export([
    roots/0
    , fields/1
    , desc/1
]).

-import(hoconsc, [enum/1]).

roots() -> [plugin_postgresql].

fields(plugin_postgresql) ->
    [
        {connection, ?HOCON(?R_REF(connection), #{desc => ?DESC("postgresql_connection")})},
        {topics, ?HOCON(?ARRAY(?R_REF(topic)),
            #{
                required => true,
                default => [],
                desc => ?DESC("topics")
            })}
    ];
fields(connection) ->
    [
        {server, ?HOCON(binary(),
            #{
                required => true,
                desc => ?DESC("postgresql_server"),
                default => "localhost:5432"
            })},
        {database, ?HOCON(binary(),
            #{
                required => true,
                desc => ?DESC("database")
            })},
        {username, ?HOCON(binary(),
            #{
                desc => ?DESC("username")
            })},
        {password, emqx_connector_schema_lib:password_field()},
        {ssl, ?HOCON(?R_REF(ssl),
            #{
                desc => ?DESC("ssl")
            }
        )},
        {pool_size, ?HOCON(pos_integer(),
            #{
                desc => ?DESC("pool_size"),
                default => 8
            })},
        {health_check_interval, ?HOCON(emqx_schema:timeout_duration_ms(),
            #{
                default => <<"30s">>,
                desc => ?DESC("health_check_interval")
            })}
    ];
fields(ssl) ->
    Schema = emqx_schema:client_ssl_opts_schema(#{}),
    lists:keydelete("user_lookup_fun", 1, Schema);
fields(topic) ->
    [
        {filter, ?HOCON(binary(),
            #{
                desc => ?DESC("topic_filter"),
                default => <<"test/#">>
            })},
        {name, ?HOCON(string(),
            #{
                desc => ?DESC("topic_name"),
                default => "emqx_test"
            })},
        {table, ?HOCON(binary(),
            #{
                desc => ?DESC("topic_table"),
                default => <<"mqtt">>
            }
        )}
    ].

desc(_) ->
    undefined.

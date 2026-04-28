-module(emqx_plugin_postgresql_app).

-behaviour(application).

-emqx_plugin(?MODULE).

-export([
    start/2
    , stop/1
]).

start(_StartType, _StartArgs) ->
    {ok, Sup} = emqx_plugin_postgresql_sup:start_link(),
    emqx_plugin_postgresql:load(),

    emqx_ctl:register_command(emqx_plugin_postgresql, {emqx_plugin_postgresql_cli, cmd}),
    {ok, Sup}.

stop(_State) ->
    emqx_ctl:unregister_command(emqx_plugin_postgresql),
    emqx_plugin_postgresql:unload().

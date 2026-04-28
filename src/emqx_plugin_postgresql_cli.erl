-module(emqx_plugin_postgresql_cli).

-export([cmd/1]).

cmd(["reload"]) ->
    emqx_plugin_postgresql:reload(),
    emqx_ctl:print("topics configuration reload complete.\n");

cmd(_) ->
    emqx_ctl:usage([{"emqx_plugin_postgresql reload", "Reload topics"}]).

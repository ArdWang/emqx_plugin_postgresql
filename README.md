# emqx_plugin_postgresql
this is emqx_plugin_postgresql
```
❯ 2026-04-28T17:23:02.873700+08:00 [warning] msg: alarm_is_deactivated, name: <<"emqx_plugin:postgresql_connector">>                                                                            
2026-04-28T17:23:02.873986+08:00 [error] crasher: initial call: application_master:init/4, pid: <0.3136.0>, registered_name: [], exit:                                                          
{{bad_return,{{emqx_plugin_postgresql_app,start,[normal,[]]},{'EXIT',{{badmatch,error},[{emqx_plugin_postgresql,load,1,[{file,"/Users/Project/278161009/Gitee/emqx/emqx_plugin_5.4/emqx_plugin_ 
postgresql/src/emqx_plugin_postgresql.erl"},{line,27}]},{emqx_plugin_postgresql_app,start,2,[{file,"/Users/Project/278161009/Gitee/emqx/emqx_plugin_5.4/emqx_plugin_postgresql/src/emqx_plugin_ 
postgresql_app.erl"},{line,14}]},{application_master,start_it_old,4,[{file,"application_master.erl"},{line,293}]}]}}}},[{application_master,init,4,[{file,"application_master.erl"},{line,142}] 
},{proc_lib,init_p_do_apply,3,[{file,"proc_lib.erl"},{line,241}]}]}, ancestors: [<0.3135.0>], message_queue_len: 1, messages: [{'EXIT',<0.3137.0>,normal}], links: [<0.3135.0>,<0.2039.0>],     
dictionary: [], trap_exit: true, status: running, heap_size: 376, stack_size: 28, reductions: 170; neighbours:                                                                                  
2026-04-28T17:23:02.874364+08:00 [alert] msg: failed_to_start_plugin, reason: #{error => "failed_to_start_plugin_app",reason =>                                                                 
{bad_return,{{emqx_plugin_postgresql_app,start,[normal,[]]},{'EXIT',{{badmatch,error},[{emqx_plugin_postgresql,load,1,[{file,"/Users/Project/278161009/Gitee/emqx/emqx_plugin_5.4/emqx_plugin_p 
ostgresql/src/emqx_plugin_postgresql.erl"},{line,27}]},{emqx_plugin_postgresql_app,start,2,[{file,"/Users/Project/278161009/Gitee/emqx/emqx_plugin_5.4/emqx_plugin_postgresql/src/emqx_plugin_p 
ostgresql_app.erl"},{line,14}]},{application_master,start_it_old,4,[{file,"application_master.erl"},{line,293}]}]}}}},app => emqx_plugin_postgresql,err_app => emqx_plugin_postgresql}          
2026-04-28T17:23:02.924660+08:00 [warning] msg: configured_plugin_not_installed, name_vsn: emqx_plugin_mongodb-0.2.7 这个是什么错误 这个错误了                                                  

⏺ 这是一个崩溃连锁反应。问题出在 emqx_plugin_postgresql.erl:27：
                                                                                           
  {ok, _} = start_resource(Connection),                                                                                                                                                         
                                                                                                                                                                                                
  当之前 PostgreSQL 连接失败（invalid_password），start_resource 返回了 error 而不是 {ok, _}，导致整个插件启动崩溃。                                                                            
                                                                                                                                                                                                
  根本原因：代码中 start_resource_if_enabled 在出错时直接返回裸 error，没有包装成 tuple。让我看一下修复一下。                                                                                   
                                                                                                                                                                                              
  Read 2 files (ctrl+o to expand)                                                                                                                                                               
                                                                                                                                                                                              
⏺ 问题清楚了。当 start_resource 失败时返回裸 error，导致 load/0 中 {ok, _} = start_resource(...) 模式匹配崩溃。需要修复错误处理，让失败时优雅返回而不是 crash。   
```
%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2009-2012 Marc Worrell
%% Date: 2009-04-09
%%
%% @doc Model for the zotonic config table. Performs a fallback to the site configuration when 
%% a key is not defined in the configuration table.

%% Copyright 2009-2012 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(m_config).
-author("Marc Worrell <marc@worrell.nl").

-behaviour(gen_model).

%% interface functions
-export([
    m_find_value/3,
    m_to_list/2,
    m_value/2,
    all/1,
    get/2,
    get/3,
    get_value/3,
    get_value/4,
    set_value/4,
    set_prop/5,
    exists/3,
    version/3,
    delete/3,
    
    zynamo_delete/3,
    zynamo_get/2,
    zynamo_put/4,
    zynamo_list/2
]).

-include_lib("zotonic.hrl").
-include_lib("deps/zynamo/include/zynamo.hrl").

%% @doc Fetch the value for the key from a model source
%% @spec m_find_value(Key, Source, Context) -> term()
m_find_value(Module, #m{value=undefined} = M, _Context) ->
    M#m{value=Module};
m_find_value(Key, #m{value=Module}, Context) ->
    get(Module, Key, Context).

%% @doc Transform a m_config value to a list, used for template loops
%% @spec m_to_list(Source, Context) -> List
m_to_list(#m{value=undefined}, Context) ->
    all(Context);
m_to_list(#m{value=Module}, Context) ->
    get(Module, Context).

%% @doc Transform a model value so that it can be formatted or piped through filters
%% @spec m_value(Source, Context) -> term()
m_value(#m{value=undefined}, Context) ->
    all(Context);
m_value(#m{value=Module}, Context) ->
    get(Module, Context).
    

%% @doc Return all configurations from the configuration table. Returns a nested proplist (module, key)
all(Context) ->
    case z_depcache:get(config, Context) of
        {ok, Cs} ->
            Cs;
        undefined ->
            Cs = case z_db:has_connection(Context) of
                    true -> z_db:assoc_props("select * from config where not is_gone order by module, key", Context);
                    false -> []
                 end,
            Indexed = [ {M, z_utils:index_proplist(key, CMs)} || {M,CMs} <- z_utils:group_proplists(module, Cs) ],
            z_depcache:set(config, Indexed, ?DAY, Context),
            Indexed
    end.


%% @doc Get the list of configuration key for the module.
get(Module, Context) when is_atom(Module) ->
    ConfigProps = case z_depcache:get_subkey(config, Module, Context) of
        {ok, undefined} ->
            [];
        {ok, Cs} ->
            Cs;
        undefined ->
            All = all(Context),
            proplists:get_value(Module, All, [])
    end,
    case m_site:get(Module, Context) of
        L when is_list(L) -> z_convert:to_list(ConfigProps) ++ L;
        _ -> ConfigProps
    end.
    
%% @doc Get a configuration value for the given module/key combination.
%% @spec get(Module::atom(), Key::atom(), #context{}) -> Value | undefined
get(Module, Key, Context) when is_atom(Module) andalso is_atom(Key) ->
    Value = case z_depcache:get_subkey(config, Module, Context) of
        {ok, undefined} ->
            undefined;
        {ok, Cs} ->
            proplists:get_value(Key, Cs);
        undefined ->
            All = all(Context),
            case proplists:get_value(Module, All) of
                undefined -> undefined;
                Cs -> proplists:get_value(Key, Cs)
            end
    end,
    case Value of 
        undefined ->
            case m_site:get(Module, Key, Context) of
                undefined -> Value;
                V -> [{value,V}]
            end;
        _ ->
            Value
    end.


get_value(Module, Key, Context) when is_atom(Module) andalso is_atom(Key) ->
    Value = case get(Module, Key, Context) of
        undefined -> undefined;
        Cfg -> proplists:get_value(value, Cfg)
    end,
    case Value of
        undefined -> m_site:get(Module, Key, Context);
        _ -> Value
    end.


get_value(Module, Key, Default, Context) when is_atom(Module) andalso is_atom(Key) ->
    case get_value(Module, Key, Context) of
        undefined -> Default;
        Value -> Value
    end.


%% @doc Set a "simple" config value.
-spec set_value(Module::atom(), Key::atom(), Value::iolist(), #context{}) -> ok | {error, term()}.
set_value(Module, Key, Value, Context) ->
    set_prop(Module, Key, value, z_convert:to_binary(Value), Context).


%% @doc Set a "complex" config value.
-spec set_prop(Module::atom(), Key::atom(), Prop::atom(), PropValue::any(), #context{}) -> ok | {error, term()}.
set_prop(Module, Key, Prop, PropValue, Context) ->
    case zynamo_request:get(Context#context.host, config, {Module, Key}, [{result, merge}]) of
        #zynamo_result{status=ok, is_found=IsFound, is_gone=IsGone} when not IsFound; IsGone ->
            set_prop1(Module, Key, Prop, PropValue, [{Prop, PropValue}], Context);
        #zynamo_result{status=ok, value=CurrProps} ->
            NewProps = z_utils:prop_replace(Prop, PropValue, CurrProps),
            set_prop1(Module, Key, Prop, PropValue, NewProps, Context);
        #zynamo_result{status=Reason} ->
            {error, Reason};
        {error, _} = Error ->
            Error
    end.

set_prop1(Module, Key, Prop, PropValue, Props, Context) ->
    case zynamo_request:put(Context#context.host, config, 
                            {Module, Key},
                            zynamo_version:timestamp(),
                            Props,
                            [{n,all},{result,merge}])
    of
        #zynamo_result{status=ok} ->
            case Prop of
                value -> z_notifier:notify(#m_config_update_prop{module=Module, key=Key, value=PropValue}, Context);
                _ -> z_notifier:notify(#m_config_update_prop{module=Module, key=Key, prop=Prop, value=PropValue}, Context)
            end,
            ok;
        #zynamo_result{status=Reason} ->
            {error, Reason};
        {error, _} = Error ->
            Error
    end.



%% @doc Delete the specified module/key combination
-spec delete(Module::atom(), Key::atom(), #context{}) -> ok | {error, any()}.
delete(Module, Key, Context) ->
    case zynamo_request:delete(Context#context.host, config,
                               {Module,Key}, zynamo_version:timestamp(),
                               [{n,all},{result,merge}]) 
    of
        #zynamo_result{status=ok} -> ok;
        #zynamo_result{status=Reason} -> {error, Reason};
        {error, _Reason} = Error -> Error
    end.


%% @doc Return the current version of a config key. undefined if the key doesn't exist.
version(Module, Key, Context) ->
    z_db:q1("select version from config where module = $1 and key = $2", [Module, Key], Context).

exists(Module, Key, Context) ->
    version(Module, Key, Context) /= undefined.


%%====================================================================
%% Zynamo callback routines, performing the actual updates on the db
%%====================================================================


zynamo_delete(Host, {Module, Key} = MK, Version) ->
    Context = z_context:new(Host),
    Result = z_db:transaction(
            fun(Ctx) ->
                CurrVersion = version(Module, Key, Ctx),
                case zynamo_version:is_newer(Version, CurrVersion) of
                    true ->
                        % Keep in database, in case another node has an old value
                        case z_db:q("update config set
                                        is_gone = true,
                                        version = $3,
                                        props = $4,
                                        value = $5,
                                        modified = now()
                                     where module = $1
                                       and key = $2", 
                                    [Module, Key, Version, [], <<>>], 
                                    Ctx)
                        of
                            1 ->
                                #zynamo_service_result{
                                    key=MK,
                                    is_gone=true,
                                    version=Version
                                };
                            0 ->
                                % Always register as gone, in case another node has an old value
                                1 = z_db:q("insert into config (module, key, version, props, value, is_gone, modified)
                                            values ($1, $2, $3, $4, $5, true, now())",
                                           [Module, Key, Version, [], <<>>], 
                                           Ctx),
                                #zynamo_service_result{
                                    key=MK,
                                    is_gone=true,
                                    version=Version
                                }
                        end;
                    false ->
                        case zynamo_version:is_equal(Version, CurrVersion) of
                            true ->
                                #zynamo_service_result{
                                    key=MK,
                                    is_gone=true,
                                    version=CurrVersion
                                };
                            false ->
                                #zynamo_service_result{
                                    status=conflict,
                                    key=MK,
                                    version=CurrVersion
                                }
                        end
                end
            end,
            Context),
    case Result of
        #zynamo_service_result{status=ok} ->
            z_depcache:flush(config, Context),
            z_notifier:notify(#m_config_update{module=Module, key=Key, value=undefined}, Context);
        _ ->
            nop
    end,
    Result.


zynamo_get(Host, {Module, Key}=MK) ->
    Context = z_context:new(Host),
    case z_db:assoc_props_row("select * from config where module = $1 and key = $2", [Module, Key], Context) of
        undefined -> 
            #zynamo_service_result{
                is_found=false, 
                key=MK
            };
        Props ->
            #zynamo_service_result{
                is_found=true,
                is_gone=proplists:get_value(is_gone, Props),
                key=MK,
                version=proplists:get_value(version, Props),
                value=Props
            }
    end.


% Optimized versions for data sync
zynamo_list(Host, #zynamo_list_args{offset={key, undefined}, return_version=true, return_value=false, return_gone=true, limit=Limit}) ->
    sync_list_rows(z_db:q("select module, key, version, is_gone
                           from config 
                           order by module, key 
                           limit $1", [Limit], z_context:new(Host)));
zynamo_list(Host, #zynamo_list_args{offset={key, {Module,Key}}, return_version=true, return_value=false, return_gone=true, limit=Limit}) ->
    sync_list_rows(z_db:q("select module, key, version, is_gone
                           from config 
                           where (module = $2 and key > $3)
                              or module > $2
                           order by module, key
                           limit $1", [Limit, Module, Key], z_context:new(Host)));
% Generic list commands
zynamo_list(Host, #zynamo_list_args{offset={key, undefined}, return_gone=true, limit=Limit} = ListArgs) ->
    Sql = "select * from config order by module, key limit $1",
    SqlArgs = [Limit],
    zynamo_list_sql(Host, ListArgs, Sql, SqlArgs);
zynamo_list(Host, #zynamo_list_args{offset={key, undefined}, return_gone=false, limit=Limit} = ListArgs) ->
    Sql = "select * from config where not is_gone order by module, key limit $1",
    SqlArgs = [Limit],
    zynamo_list_sql(Host, ListArgs, Sql, SqlArgs);
zynamo_list(Host, #zynamo_list_args{offset={key, {Module,Key}}, return_gone=true, limit=Limit} = ListArgs) ->
    Sql = "select * from config where (module = $2 and key >= $3) or module > $2 order by module, key limit $1",
    SqlArgs = [Limit, Module, Key],
    zynamo_list_sql(Host, ListArgs, Sql, SqlArgs);
zynamo_list(Host, #zynamo_list_args{offset={key, {Module,Key}}, return_gone=false, limit=Limit} = ListArgs) ->
    Sql = "select * from config where not is_gone and ((module = $2 and key >= $3) or module > $2) order by module, key limit $1",
    SqlArgs = [Limit, Module, Key],
    zynamo_list_sql(Host, ListArgs, Sql, SqlArgs);
zynamo_list(Host, #zynamo_list_args{offset=Offset, return_gone=true, limit=Limit} = ListArgs) ->
    Sql = "select * from config order by module, key limit $1 offset $2",
    SqlArgs = [Limit, Offset],
    zynamo_list_sql(Host, ListArgs, Sql, SqlArgs);
zynamo_list(Host, #zynamo_list_args{offset=Offset, return_gone=false, limit=Limit} = ListArgs) ->
    Sql = "select * from config where not is_gone order by module, key limit $1 offset $2",
    SqlArgs = [Limit, Offset],
    zynamo_list_sql(Host, ListArgs, Sql, SqlArgs).

    sync_list_rows([]) ->
        #zynamo_service_result{value='$end_of_table'};
    sync_list_rows(Rs) ->
        #zynamo_service_result{
            value=[
                    #zynamo_service_result{
                        is_gone=IsGone,
                        key={z_convert:to_atom(M), z_convert:to_atom(K)},
                        version=Version
                    }
                    || {M, K, Version, IsGone} <- Rs
            ]}.

    zynamo_list_sql(Host, ListArgs, Sql, SqlArgs) ->
        #zynamo_list_args{return_value=WithValue, return_version=WithVersion} = ListArgs,
        Context = z_context:new(Host),
        case z_db:assoc_props(Sql, SqlArgs, Context) of
            [] ->
                #zynamo_service_result{value='$end_of_table'};
            Rs ->
                #zynamo_service_result{
                    value=[
                        #zynamo_service_result{
                            is_gone=proplists:get_value(is_gone, R),
                            key={z_convert:to_atom(proplists:get_value(module, R)), 
                                 z_convert:to_atom(proplists:get_value(key, R))},
                            version=case WithVersion of
                                        true -> proplists:get_value(version, R);
                                        false -> undefined
                                    end,
                            value=case WithValue of true -> R; false -> undefined end
                        }
                        || R <- Rs
                    ]}
        end.

zynamo_put(Host, {Module, Key} = MK, Version, Props) ->
    Context = z_context:new(Host),
    Cols = z_db:column_names(config, Context),
    OtherProps = z_utils:prop_delete(Cols, Props),
    PropValue = case proplists:get_value(value, Props) of
                    undefined -> <<>>;
                    PV -> PV
                end,
    Result = z_db:transaction(
            fun(Ctx) ->
                CurrVersion = version(Module, Key, Ctx),
                case zynamo_version:is_newer(Version, CurrVersion) of
                    true ->
                        case CurrVersion of 
                            undefined ->
                                1 = z_db:q("insert into config (module, key, props, value, version, modified)
                                            values ($1, $2, $3, $4, $5, now())",
                                           [Module, Key, OtherProps, PropValue, Version],
                                           Ctx);
                            _Exists ->
                                1 = z_db:q("update config set
                                                is_gone = false,
                                                props = $3,
                                                value = $4,
                                                version = $5,
                                                modified = now()
                                            where module = $1
                                              and key = $2",
                                           [Module, Key, OtherProps, PropValue, Version],
                                           Ctx)
                        end,
                        #zynamo_service_result{
                            key=MK,
                            version=Version
                        };
                    false ->
                        case zynamo_version:is_equal(Version, CurrVersion) of
                            true -> 
                                #zynamo_service_result{
                                    key=MK,
                                    version=CurrVersion
                                };
                            false ->
                                #zynamo_service_result{
                                    status=conflict,
                                    key=MK,
                                    version=CurrVersion
                                }
                        end
                end
            end,
            Context),
    case Result of
        #zynamo_service_result{status=ok} ->
            z_depcache:flush(config, Context),
            z_notifier:notify(#m_config_update_prop{module=Module, key=Key, prop=OtherProps, value=PropValue}, Context);
        _ ->
            nop
    end,
    Result.



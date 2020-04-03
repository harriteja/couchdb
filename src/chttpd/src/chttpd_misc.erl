% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(chttpd_misc).

-export([
    handle_all_dbs_req/1,
    handle_deleted_dbs_req/1,
    handle_dbs_info_req/1,
    handle_favicon_req/1,
    handle_favicon_req/2,
    handle_replicate_req/1,
    handle_reload_query_servers_req/1,
    handle_task_status_req/1,
    handle_up_req/1,
    handle_utils_dir_req/1,
    handle_utils_dir_req/2,
    handle_uuids_req/1,
    handle_welcome_req/1,
    handle_welcome_req/2
]).

-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_mrview/include/couch_mrview.hrl").

-import(chttpd,
    [send_json/2,send_json/3,send_method_not_allowed/2,
    send_chunk/2,start_chunked_response/3]).

-define(MAX_DB_NUM_FOR_DBS_INFO, 100).

% httpd global handlers

handle_welcome_req(Req) ->
    handle_welcome_req(Req, <<"Welcome">>).

handle_welcome_req(#httpd{method='GET'}=Req, WelcomeMessage) ->
    send_json(Req, {[
        {couchdb, WelcomeMessage},
        {version, list_to_binary(couch_server:get_version())},
        {git_sha, list_to_binary(couch_server:get_git_sha())},
        {uuid, couch_server:get_uuid()},
        {features, get_features()}
        ] ++ case config:get("vendor") of
        [] ->
            [];
        Properties ->
            [{vendor, {[{?l2b(K), ?l2b(V)} || {K, V} <- Properties]}}]
        end
    });
handle_welcome_req(Req, _) ->
    send_method_not_allowed(Req, "GET,HEAD").

get_features() ->
    case clouseau_rpc:connected() of
        true ->
            [search | config:features()];
        false ->
            config:features()
    end.

handle_favicon_req(Req) ->
    handle_favicon_req(Req, get_docroot()).

handle_favicon_req(#httpd{method='GET'}=Req, DocumentRoot) ->
    {DateNow, TimeNow} = calendar:universal_time(),
    DaysNow = calendar:date_to_gregorian_days(DateNow),
    DaysWhenExpires = DaysNow + 365,
    DateWhenExpires = calendar:gregorian_days_to_date(DaysWhenExpires),
    CachingHeaders = [
        %favicon should expire a year from now
        {"Cache-Control", "public, max-age=31536000"},
        {"Expires", couch_util:rfc1123_date({DateWhenExpires, TimeNow})}
    ],
    chttpd:serve_file(Req, "favicon.ico", DocumentRoot, CachingHeaders);
handle_favicon_req(Req, _) ->
    send_method_not_allowed(Req, "GET,HEAD").

handle_utils_dir_req(Req) ->
    handle_utils_dir_req(Req, get_docroot()).

handle_utils_dir_req(#httpd{method='GET'}=Req, DocumentRoot) ->
    "/" ++ UrlPath = chttpd:path(Req),
    case chttpd:partition(UrlPath) of
    {_ActionKey, "/", RelativePath} ->
        % GET /_utils/path or GET /_utils/
        CachingHeaders = [{"Cache-Control", "private, must-revalidate"}],
        EnableCsp = config:get("csp", "enable", "false"),
        Headers = maybe_add_csp_headers(CachingHeaders, EnableCsp),
        chttpd:serve_file(Req, RelativePath, DocumentRoot, Headers);
    {_ActionKey, "", _RelativePath} ->
        % GET /_utils
        RedirectPath = chttpd:path(Req) ++ "/",
        chttpd:send_redirect(Req, RedirectPath)
    end;
handle_utils_dir_req(Req, _) ->
    send_method_not_allowed(Req, "GET,HEAD").

maybe_add_csp_headers(Headers, "true") ->
    DefaultValues = "default-src 'self'; img-src 'self' data:; font-src 'self'; "
                    "script-src 'self' 'unsafe-eval'; style-src 'self' 'unsafe-inline';",
    Value = config:get("csp", "header_value", DefaultValues),
    [{"Content-Security-Policy", Value} | Headers];
maybe_add_csp_headers(Headers, _) ->
    Headers.

handle_all_dbs_req(#httpd{method='GET'}=Req) ->
    #mrargs{
        start_key = StartKey,
        end_key = EndKey,
        direction = Dir,
        limit = Limit,
        skip = Skip
    } = couch_mrview_http:parse_params(Req, undefined),

    Options = [
        {start_key, StartKey},
        {end_key, EndKey},
        {dir, Dir},
        {limit, Limit},
        {skip, Skip}
    ],

    % Eventually the Etag for this request will be derived
    % from the \xFFmetadataVersion key in fdb
    Etag = <<"foo">>,

    {ok, Resp} = chttpd:etag_respond(Req, Etag, fun() ->
        {ok, Resp} = chttpd:start_delayed_json_response(Req, 200, [{"ETag",Etag}]),
        Callback = fun all_dbs_callback/2,
        Acc = #vacc{req=Req,resp=Resp},
        fabric2_db:list_dbs(Callback, Acc, Options)
    end),
    case is_record(Resp, vacc) of
        true -> {ok, Resp#vacc.resp};
        _ -> {ok, Resp}
    end;
handle_all_dbs_req(Req) ->
    send_method_not_allowed(Req, "GET,HEAD").

handle_deleted_dbs_req(#httpd{method='GET', path_parts=[_]}=Req) ->
    deleted_dbs_get_req(Req);
handle_deleted_dbs_req(#httpd{method='POST', path_parts=[_]}=Req) ->
    deleted_dbs_post_req(Req);
handle_deleted_dbs_req(#httpd{path_parts = PP}=Req) when length(PP) == 1 ->
    send_method_not_allowed(Req, "GET,HEAD,POST");
handle_deleted_dbs_req(#httpd{method='DELETE', path_parts=[_, DbName]}=Req) ->
    remove_deleted_req(Req, DbName);
handle_deleted_dbs_req(#httpd{path_parts = PP}=Req) when length(PP) == 2 ->
    send_method_not_allowed(Req, "HEAD,DELETE");
handle_deleted_dbs_req(Req) ->
    chttpd:send_error(Req, not_found).

deleted_dbs_get_req(Req) ->
    couch_httpd:verify_is_server_admin(Req),
    case ?JSON_DECODE(couch_httpd:qs_value(Req, "key", "null")) of
        null ->
            deleted_dbs_info_req(Req);
        DbName ->
            deleted_db_info_req(Req, DbName)
    end.

deleted_dbs_info_req(#httpd{user_ctx=Ctx}=Req) ->
    % Eventually the Etag for this request will be derived
    % from the \xFFmetadataVersion key in fdb
    Etag = <<"foo">>,

    {ok, Resp} = chttpd:etag_respond(Req, Etag, fun() ->
        {ok, Resp} = chttpd:start_delayed_json_response(Req, 200, [{"ETag",Etag}]),
        Callback = fun dbs_info_callback/2,
        Acc = #vacc{req=Req,resp=Resp},
        fabric2_db:list_deleted_dbs(Callback, Acc, [{user_ctx, Ctx}])
    end),
    case is_record(Resp, vacc) of
        true -> {ok, Resp#vacc.resp};
        _ -> {ok, Resp}
    end.

deleted_db_info_req(#httpd{user_ctx=Ctx}=Req, DbName) ->
    case fabric2_db:deleted_dbs_info(DbName, [{user_ctx, Ctx}]) of
        {ok, Result} ->
            {ok, Resp} = chttpd:start_json_response(Req, 200),
            send_chunk(Resp, "["),
            lists:foldl(fun({Timestamp, Info}, AccSeparator) ->
                Json = ?JSON_ENCODE({[
                    {key, DbName},
                    {timestamp, Timestamp},
                    {value, {Info}}
                ]}),
                send_chunk(Resp, AccSeparator ++ Json),
                "," % AccSeparator now has a comma
            end, "", Result),
            send_chunk(Resp, "]"),
            chttpd:end_json_response(Resp);
        Error ->
            throw(Error)
    end.

deleted_dbs_post_req(#httpd{user_ctx=Ctx}=Req) ->
    couch_httpd:verify_is_server_admin(Req),
    chttpd:validate_ctype(Req, "application/json"),
    {JsonProps} = chttpd:json_body_obj(Req),
    {UndeleteJson} =  case couch_util:get_value(<<"undelete">>, JsonProps) of
        undefined ->
            throw({bad_request,
                <<"POST body must include `undeleted` parameter.">>});
        UndeleteJson0 ->
            UndeleteJson0
    end,
    DbName = case couch_util:get_value(<<"source">>, UndeleteJson) of
        undefined ->
            throw({bad_request,
                <<"POST body must include `source` parameter.">>});
        DbName0 ->
            DbName0
    end,
    TimeStamp = case couch_util:get_value(<<"source_timestamp">>, UndeleteJson) of
        undefined ->
            throw({bad_request,
                <<"POST body must include `source_timestamp` parameter.">>});
        TimeStamp0 ->
            TimeStamp0
    end,
    TgtDbName = case couch_util:get_value(<<"target">>, UndeleteJson) of
        undefined ->  DbName;
        TgtDbName0 -> TgtDbName0
    end,
    case fabric2_db:undelete(DbName, TgtDbName, TimeStamp, [{user_ctx, Ctx}]) of
        ok ->
            send_json(Req, 200, {[{ok, true}]});
        {error, file_exists} ->
            chttpd:send_error(Req, file_exists);
        {error, not_found} ->
            chttpd:send_error(Req, not_found);
        Error ->
            throw(Error)
    end.

remove_deleted_req(#httpd{user_ctx=Ctx}=Req, DbName) ->
    couch_httpd:verify_is_server_admin(Req),
    TS = case ?JSON_DECODE(couch_httpd:qs_value(Req, "timestamp", "null")) of
        null ->
            throw({bad_request, "`timestamp` parameter is not provided."});
        TS0 ->
           TS0
    end,
    case fabric2_db:delete(DbName, [{user_ctx, Ctx}, {deleted_at, TS}]) of
        ok ->
            send_json(Req, 200, {[{ok, true}]});
        {error, not_found} ->
            chttpd:send_error(Req, not_found);
        Error ->
            throw(Error)
    end.

all_dbs_callback({meta, _Meta}, #vacc{resp=Resp0}=Acc) ->
    {ok, Resp1} = chttpd:send_delayed_chunk(Resp0, "["),
    {ok, Acc#vacc{resp=Resp1}};
all_dbs_callback({row, Row}, #vacc{resp=Resp0}=Acc) ->
    Prepend = couch_mrview_http:prepend_val(Acc),
    DbName = couch_util:get_value(id, Row),
    {ok, Resp1} = chttpd:send_delayed_chunk(Resp0, [Prepend, ?JSON_ENCODE(DbName)]),
    {ok, Acc#vacc{prepend=",", resp=Resp1}};
all_dbs_callback(complete, #vacc{resp=Resp0}=Acc) ->
    {ok, Resp1} = chttpd:send_delayed_chunk(Resp0, "]"),
    {ok, Resp2} = chttpd:end_delayed_json_response(Resp1),
    {ok, Acc#vacc{resp=Resp2}};
all_dbs_callback({error, Reason}, #vacc{resp=Resp0}=Acc) ->
    {ok, Resp1} = chttpd:send_delayed_error(Resp0, Reason),
    {ok, Acc#vacc{resp=Resp1}}.

handle_dbs_info_req(#httpd{method = 'GET'} = Req) ->
    ok = chttpd:verify_is_server_admin(Req),

    #mrargs{
        start_key = StartKey,
        end_key = EndKey,
        direction = Dir,
        limit = Limit,
        skip = Skip
    } = couch_mrview_http:parse_params(Req, undefined),

    Options = [
        {start_key, StartKey},
        {end_key, EndKey},
        {dir, Dir},
        {limit, Limit},
        {skip, Skip}
    ],

    % TODO: Figure out if we can't calculate a valid
    % ETag for this request. \xFFmetadataVersion won't
    % work as we don't bump versions on size changes

    {ok, Resp} = chttpd:start_delayed_json_response(Req, 200, []),
    Callback = fun dbs_info_callback/2,
    Acc = #vacc{req = Req, resp = Resp},
    {ok, Resp} = fabric2_db:list_dbs_info(Callback, Acc, Options),
    case is_record(Resp, vacc) of
        true -> {ok, Resp#vacc.resp};
        _ -> {ok, Resp}
    end;
handle_dbs_info_req(#httpd{method='POST', user_ctx=UserCtx}=Req) ->
    chttpd:validate_ctype(Req, "application/json"),
    Props = chttpd:json_body_obj(Req),
    Keys = couch_mrview_util:get_view_keys(Props),
    case Keys of
        undefined -> throw({bad_request, "`keys` member must exist."});
        _ -> ok
    end,
    MaxNumber = config:get_integer("chttpd",
        "max_db_number_for_dbs_info_req", ?MAX_DB_NUM_FOR_DBS_INFO),
    case length(Keys) =< MaxNumber of
        true -> ok;
        false -> throw({bad_request, too_many_keys})
    end,
    {ok, Resp} = chttpd:start_json_response(Req, 200),
    send_chunk(Resp, "["),
    lists:foldl(fun(DbName, AccSeparator) ->
        try
            {ok, Db} = fabric2_db:open(DbName, [{user_ctx, UserCtx}]),
            {ok, Info} = fabric2_db:get_db_info(Db),
            Json = ?JSON_ENCODE({[{key, DbName}, {info, {Info}}]}),
            send_chunk(Resp, AccSeparator ++ Json)
        catch error:database_does_not_exist ->
            ErrJson = ?JSON_ENCODE({[{key, DbName}, {error, not_found}]}),
            send_chunk(Resp, AccSeparator ++ ErrJson)
        end,
        "," % AccSeparator now has a comma
    end, "", Keys),
    send_chunk(Resp, "]"),
    chttpd:end_json_response(Resp);
handle_dbs_info_req(Req) ->
    send_method_not_allowed(Req, "GET,HEAD,POST").

dbs_info_callback({meta, _Meta}, #vacc{resp = Resp0} = Acc) ->
    {ok, Resp1} = chttpd:send_delayed_chunk(Resp0, "["),
    {ok, Acc#vacc{resp = Resp1}};
dbs_info_callback({row, Props}, #vacc{resp = Resp0} = Acc) ->
    Prepend = couch_mrview_http:prepend_val(Acc),
    Chunk = [Prepend, ?JSON_ENCODE({Props})],
    {ok, Resp1} = chttpd:send_delayed_chunk(Resp0, Chunk),
    {ok, Acc#vacc{prepend = ",", resp = Resp1}};
dbs_info_callback(complete, #vacc{resp = Resp0} = Acc) ->
    {ok, Resp1} = chttpd:send_delayed_chunk(Resp0, "]"),
    {ok, Resp2} = chttpd:end_delayed_json_response(Resp1),
    {ok, Acc#vacc{resp = Resp2}};
dbs_info_callback({error, Reason}, #vacc{resp = Resp0} = Acc) ->
    {ok, Resp1} = chttpd:send_delayed_error(Resp0, Reason),
    {ok, Acc#vacc{resp = Resp1}}.

handle_task_status_req(#httpd{method='GET'}=Req) ->
    ok = chttpd:verify_is_server_admin(Req),
    {Replies, _BadNodes} = gen_server:multi_call(couch_task_status, all),
    Response = lists:flatmap(fun({Node, Tasks}) ->
        [{[{node,Node} | Task]} || Task <- Tasks]
    end, Replies),
    send_json(Req, lists:sort(Response));
handle_task_status_req(Req) ->
    send_method_not_allowed(Req, "GET,HEAD").

handle_replicate_req(#httpd{method='POST', user_ctx=Ctx} = Req) ->
    chttpd:validate_ctype(Req, "application/json"),
    %% see HACK in chttpd.erl about replication
    PostBody = get(post_body),
    case replicate(PostBody, Ctx) of
        {ok, {continuous, RepId}} ->
            send_json(Req, 202, {[{ok, true}, {<<"_local_id">>, RepId}]});
        {ok, {cancelled, RepId}} ->
            send_json(Req, 200, {[{ok, true}, {<<"_local_id">>, RepId}]});
        {ok, {JsonResults}} ->
            send_json(Req, {[{ok, true} | JsonResults]});
        {ok, stopped} ->
            send_json(Req, 200, {[{ok, stopped}]});
        {error, not_found=Error} ->
            chttpd:send_error(Req, Error);
        {error, {_, _}=Error} ->
            chttpd:send_error(Req, Error);
        {_, _}=Error ->
            chttpd:send_error(Req, Error)
    end;
handle_replicate_req(Req) ->
    send_method_not_allowed(Req, "POST").

replicate({Props} = PostBody, Ctx) ->
    case couch_util:get_value(<<"cancel">>, Props) of
    true ->
        cancel_replication(PostBody, Ctx);
    _ ->
        Node = choose_node([
            couch_util:get_value(<<"source">>, Props),
            couch_util:get_value(<<"target">>, Props)
        ]),
        case rpc:call(Node, couch_replicator, replicate, [PostBody, Ctx]) of
        {badrpc, Reason} ->
            erlang:error(Reason);
        Res ->
            Res
        end
    end.

cancel_replication(PostBody, Ctx) ->
    {Res, _Bad} = rpc:multicall(couch_replicator, replicate, [PostBody, Ctx]),
    case [X || {ok, {cancelled, _}} = X <- Res] of
    [Success|_] ->
        % Report success if at least one node canceled the replication
        Success;
    [] ->
        case lists:usort(Res) of
        [UniqueReply] ->
            % Report a universally agreed-upon reply
            UniqueReply;
        [] ->
            {error, badrpc};
        Else ->
            % Unclear what to do here -- pick the first error?
            % Except try ignoring any {error, not_found} responses
            % because we'll always get two of those
            hd(Else -- [{error, not_found}])
        end
    end.

choose_node(Key) when is_binary(Key) ->
    Checksum = erlang:crc32(Key),
    Nodes = lists:sort([node()|erlang:nodes()]),
    lists:nth(1 + Checksum rem length(Nodes), Nodes);
choose_node(Key) ->
    choose_node(term_to_binary(Key)).

handle_reload_query_servers_req(#httpd{method='POST'}=Req) ->
    chttpd:validate_ctype(Req, "application/json"),
    ok = couch_proc_manager:reload(),
    send_json(Req, 200, {[{ok, true}]});
handle_reload_query_servers_req(Req) ->
    send_method_not_allowed(Req, "POST").

handle_uuids_req(Req) ->
    couch_httpd_misc_handlers:handle_uuids_req(Req).


handle_up_req(#httpd{method='GET'} = Req) ->
    case config:get("couchdb", "maintenance_mode") of
    "true" ->
        send_json(Req, 404, {[{status, maintenance_mode}]});
    "nolb" ->
        send_json(Req, 404, {[{status, nolb}]});
    _ ->
        try
            fabric2_db:list_dbs([{limit, 0}]),
            send_json(Req, 200, {[{status, ok}]})
        catch error:{timeout, _} ->
            send_json(Req, 404, {[{status, backend_unavailable}]})
        end
    end;

handle_up_req(Req) ->
    send_method_not_allowed(Req, "GET,HEAD").

get_docroot() ->
    % if the env var isn’t set, let’s not throw an error, but
    % assume the current working dir is what we want
    os:getenv("COUCHDB_FAUXTON_DOCROOT", "").

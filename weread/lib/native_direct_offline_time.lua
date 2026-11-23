-- Resolve an open native chapter in a subprocess before recording offline
-- statistics. A reader session and account own the result; no cloud calls.
local UI=require('ui/uimanager')
local Path=require('weread.lib.native_direct_path')
local Identity=require('weread.lib.book_file_identity')
local Account=require('weread.lib.native_position_contract').account_key
local C=require('weread.lib.readtime_transfer_contract')
local M={}

function M.cancel(host)
    host._native_offline_time=nil
    if host._native_offline_time_worker then host._native_offline_time_worker:cancel() end
end

local function owns(host,ctx)
    return host._native_offline_time==ctx and host.ui==ctx.reader and ctx.reader.document==ctx.document
        and ctx.document.file==ctx.file and (host._reader_session_gen or 0)==ctx.session
        and host.library_db:accountKey()==ctx.account and host.settings:auth_scope_matches(ctx.scope)
end

function M.context(host,visible)
    local reader=host.ui;local document=reader and reader.document;local file=document and document.file
    if not Path.contains(host.settings,file) then M.cancel(host);return nil end
    local ctx=host._native_offline_time
    if ctx and not owns(host,ctx) then M.cancel(host);ctx=nil end
    if not ctx and host.offline_time and host.offline_time:enabled() and not host._weread_suspended then
        local scope=host.settings:get_auth_scope()
        local account=host.library_db and host.library_db:accountKey()
        if scope and account and Account(scope.vid)==account and host.settings:auth_scope_matches(scope) then
            ctx={reader=reader,document=document,file=file,scope=scope,account=account,
                session=host._reader_session_gen or 0,state='checking'}
            host._native_offline_time=ctx
            if not host._native_offline_time_worker then
                local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
                    scheduler=UI,codec=host.client,timeout=180} end)
                if ok then host._native_offline_time_worker=worker end
            end
            local worker=host._native_offline_time_worker
            local started=false
            if worker then
                local ok,value=pcall(worker.start,worker,function()
                    local entry=require('weread.lib.native_direct_cache').identify(host.settings,scope.vid,file,function()
                        return owns(host,ctx)
                    end)
                    if not entry then return {error='unavailable'} end
                    return {book_id=entry.book_id,file_id=entry.file_id,book_version=entry.book_version}
                end,function(value)
                    if not owns(host,ctx) or not host.offline_time:enabled() then
                        if host._native_offline_time==ctx then M.cancel(host) end
                        return
                    end
                    local identity=type(value)=='table' and C.id(value.book_id)
                        and Identity.read_document(document,value.book_id) or nil
                    if identity and C.hash(value.file_id) and C.integer(value.book_version,0,2147483647)
                        and identity.book_id==value.book_id and identity.file_id==value.file_id
                        and identity.book_version==value.book_version then
                        ctx.book_id,ctx.file_id,ctx.book_version=value.book_id,value.file_id,value.book_version
                        ctx.state='ready'
                    else ctx.state='unavailable' end
                    host.offline_time:update('source_ready')
                end)
                started=ok and value==true
            end
            if not started then ctx.state='unavailable' end
        end
    end
    local ready=ctx and ctx.state=='ready' and owns(host,ctx)
    return {book_id=ready and ctx.book_id or nil,path=file,document=document,stats=reader.statistics,visible=visible,
        native_time_file_id=ready and ctx.file_id or nil,native_time_version=ready and ctx.book_version or nil,
        native_time_state=ctx and ctx.state or 'unavailable'}
end
return M

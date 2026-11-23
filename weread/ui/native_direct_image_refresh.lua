-- Explicit reader action; improved images are saved in a separate copy.
local UI=require('ui/uimanager')
local Access=require('weread.lib.native_read_access')
local Recovery=require('weread.lib.native_read_recovery')
local Cache=require('weread.lib.native_direct_cache')
local Crypto=require('weread.lib.crypto')
local Path=require('weread.lib.native_direct_path')
local _=require('weread.lib.plugin_util').tr
local M={}
local function capture(settings,store)
    local native=Access.capture(settings,store)
    if not native then return nil end
    return {native=native,base_revision=Crypto.sha256_hex(native.scope.vid..'\0'..tostring(native.scope.epoch))}
end
local function text(value,fallback)
    if type(value)=='string' and #value<=2048 and not value:find('[%z%c]')
        and require('weread.lib.protocol').utf8_substr(value,#value)==value then return value end
    return fallback
end
function M.cancel(host)
    local ctx=host._native_direct_image_refresh;host._native_direct_image_refresh=nil
    if not ctx then return end
    if host._native_direct_image_refresh_worker then host._native_direct_image_refresh_worker:cancel() end
    Recovery.cancel(host,ctx)
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
end
function M.start(host,entry)
    local reader=host.ui;local doc=reader and reader.document;local scope=host.settings:get_auth_scope()
    local account=host.library_db and host.library_db:accountKey()
    if not doc or not scope or not account or account~=require('weread.lib.native_position_contract').account_key(scope.vid)
        or not host.settings:auth_scope_matches(scope) or not Path.contains(host.settings,doc.file)
        or not Cache.valid_entry(entry,entry and entry.book_id,scope.vid) or not entry.file_id or entry.missing_images<1 then return false end
    if not entry.catalog_sha256 then host:showInfo(_('Chapter order is unavailable. Reopen this chapter online to update it.'));return false end
    local online,connected=pcall(host.isNetworkConnected,host)
    if not online or connected~=true then host:showInfo(_('Connect to retry missing chapter images.'));return false end
    local selected=capture(host.settings)
    if not selected or selected.native.renewal_pending then
        host:showInfo(_('E-Ink authorization is required to read these chapters.'));return false
    end
    M.cancel(host)
    local book=host.settings:get_book(entry.book_id)
    if type(book)~='table' or tostring(book.book_id or book.bookId or '')~=entry.book_id then book={} end
    book={book_id=entry.book_id,title=text(book.title,entry.book_id),author=text(book.author,'')}
    local ctx={reader=reader,document=doc,file=doc.file,session=host._reader_session_gen or 0,
        account=account,scope=scope,entry=entry,selected=selected,book=book,started=os.time()}
    host._native_direct_image_refresh=ctx
    local function view_current()
        local age=os.time()-ctx.started;local ok,up=pcall(host.isNetworkConnected,host)
        return host._native_direct_image_refresh==ctx and not host._weread_suspended and age>=0 and age<=300
            and host.ui==reader and reader.document==doc and doc.file==ctx.file
            and (host._reader_session_gen or 0)==ctx.session and host.settings:auth_scope_matches(scope)
            and host.library_db:accountKey()==account and ok and up==true
    end
    local function current() return view_current() and Access.matches(host.settings,ctx.selected.native) end
    local function finish(message)
        if host._native_direct_image_refresh~=ctx then return end
        local visible=view_current();M.cancel(host)
        if visible then host:showInfo(_(message)) end
    end
    if not host._native_direct_image_refresh_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,timeout=240} end)
        if not ok then finish('Could not retry the chapter images. The current chapter was kept.');return false end
        host._native_direct_image_refresh_worker=worker
    end
    local worker=host._native_direct_image_refresh_worker
    local launch
    local function renew()
        local started=Recovery.start(host,ctx,ctx.selected,{capture=capture,is_current=view_current,
            stale=function() if host._native_direct_image_refresh==ctx then M.cancel(host) end end,
            complete=function(ok,fresh)
                ctx.selected=fresh
                if not ok then finish('E-Ink authorization expired. Please authorize again.');return end
                launch()
            end})
        if not started then finish('E-Ink authorization expired. Please authorize again.') end
    end
    launch=function()
        if not current() then M.cancel(host);return end
        ctx.generation=(ctx.generation or 0)+1;local generation=ctx.generation
        local ok,started=pcall(worker.start,worker,function()
            return require('weread.lib.native_direct_image_refresh').run(host.client,host.settings,ctx.selected.native,
                entry,ctx.file,book,current)
        end,function(result)
            if host._native_direct_image_refresh~=ctx or ctx.generation~=generation then return end
            if not current() then M.cancel(host);return end
            if type(result)=='table' and result.error=='auth_expired' then renew();return end
            if type(result)=='table' and result.error=='rate_limited' then finish('WeRead is limiting requests. Please try again later.');return end
            if type(result)=='table' and result.error=='catalog_changed' then finish('The chapter list changed. Please open it again.');return end
            if type(result)=='table' and result.kind=='unchanged' then
                finish('No additional images could be recovered. The current chapter was kept.');return
            end
            if type(result)=='table' and result.kind=='improved' and Path.contains(host.settings,result.path)
                and result.path~=ctx.file and result.book_version==entry.book_version
                and result.source_sha256==entry.source_sha256 and type(result.missing_images)=='number'
                and result.missing_images%1==0 and result.missing_images>=0 and result.missing_images<entry.missing_images then
                finish('Additional images were saved in a new chapter copy. Your current page is unchanged. Open the saved chapter list to use it.');return
            end
            finish('Could not retry the chapter images. The current chapter was kept.')
        end)
        if not ok or not started then finish('Could not retry the chapter images. The current chapter was kept.') end
    end
    host:showBusy(_('Retrying chapter images...'),function() M.cancel(host) end);ctx.busy=host.busy_message
    launch();return host._native_direct_image_refresh==ctx
end
return M

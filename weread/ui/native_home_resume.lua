-- A native chapter becomes a home shortcut only after its account, receipt,
-- EPUB and the active document have all been checked. No cloud state is changed.
local UI=require('ui/uimanager')
local Cache=require('weread.lib.native_direct_cache')
local Path=require('weread.lib.native_direct_path')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local _=require('weread.lib.plugin_util').tr
local M={}

local function account(host,scope)
    local value=host.library_db and host.library_db:accountKey()
    if not scope or type(scope.vid)~='string' or not value
        or value~=Crypto.sha256_hex('weread-library:'..scope.vid):sub(1,20)
        or not host.settings:auth_scope_matches(scope) then return nil end
    return value
end
local function owned(book,id,owner)
    return type(book)=='table' and type(id)=='string' and id~=''
        and tostring(book.book_id or book.bookId or '')==id
        and (book.book_id==nil or tostring(book.book_id)==id)
        and (book.bookId==nil or tostring(book.bookId)==id)
        and (book._library_account_key==nil or book._library_account_key==owner)
end
local function same(a,b)
    return type(a)=='table' and type(b)=='table' and a.at==b.at
        and type(a.entry)=='table' and type(b.entry)=='table'
        and a.entry.book_id==b.entry.book_id and a.entry.chapter_uid==b.entry.chapter_uid
        and a.entry.key==b.entry.key and a.entry.copy==b.entry.copy
        and a.entry.file_id==b.entry.file_id and a.entry.book_version==b.entry.book_version
        and a.entry.source_sha256==b.entry.source_sha256
end

function M.cancel(host)
    host._native_home_resume_after_wake=nil
    local ctx=host._native_home_resume
    if not ctx then return end
    host._native_home_resume=nil
    if host._native_home_resume_worker then host._native_home_resume_worker:cancel() end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
end

local function worker(host)
    if not host._native_home_resume_worker then
        local ok,value=pcall(function() return require('weread.lib.memory_worker'):new{
            scheduler=UI,codec=host.client,max_bytes=65536,timeout=180} end)
        if not ok then return nil end
        host._native_home_resume_worker=value
    end
    return host._native_home_resume_worker
end

function M.can_resume(host,book,id)
    local scope=host.settings:get_auth_scope()
    local owner=account(host,scope)
    local pointer=type(book)=='table' and book.native_home_resume
    return owner~=nil and owned(book,id,owner) and book.home_recent_account==owner
        and type(pointer)=='table' and type(pointer.at)=='number' and pointer.at==book.home_recent_at
        and type(pointer.entry)=='table'
end

local function same_reader(host,ctx)
    return not host._weread_suspended and host.ui==ctx.reader and ctx.reader.document==ctx.document
        and ctx.document.file==ctx.path and (host._reader_session_gen or 0)==ctx.session
        and account(host,ctx.scope)==ctx.owner
end

local function record(host,opened_at)
    local reader=host.ui;local document=reader and reader.document
    local path=document and document.file
    local scope=host.settings:get_auth_scope()
    local owner=account(host,scope)
    if host._weread_suspended or not owner or not Path.contains(host.settings,path) then return false end
    M.cancel(host)
    local ctx={reader=reader,document=document,path=path,scope=scope,owner=owner,
        session=host._reader_session_gen or 0,at=opened_at,recording=true}
    host._native_home_resume=ctx
    local function current()
        return host._native_home_resume==ctx and same_reader(host,ctx)
    end
    local w=worker(host)
    if not w then M.cancel(host);return false end
    local ok,started=pcall(w.start,w,function()
        local entry=Cache.identify(host.settings,scope.vid,path,current)
        local pending=entry and host._native_direct_reconnect and require('weread.lib.native_direct_pending').read(
            host.library_db,host.settings,scope,entry,current)
        return {entry=entry,pending=pending}
    end,function(value)
        if not current() then if host._native_home_resume==ctx then M.cancel(host) end;return end
        local entry=type(value)=='table' and value.entry
        if type(entry)~='table' or not Cache.valid_entry(entry,entry.book_id,scope.vid) then M.cancel(host);return end
        local identity=Identity.read_document(document,entry.book_id)
        if identity.book_id~=entry.book_id or identity.file_id~=entry.file_id
            or identity.book_version~=entry.book_version then M.cancel(host);return end
        local reconnect=package.loaded['weread.ui.native_direct_reconnect']
        if reconnect and host._native_direct_reconnect then reconnect.bind(host,entry,value.pending) end
        local book=host.settings:get_book(entry.book_id)
        if owned(book,entry.book_id,owner)
            and (type(book.home_recent_at)~='number' or book.home_recent_at<=ctx.at) then
            host.settings:patch_reading_state(entry.book_id,{home_recent_at=ctx.at,home_recent_account=owner,
                native_home_resume={at=ctx.at,entry=entry}})
        end
        M.cancel(host)
    end)
    if not ok or not started then M.cancel(host);return false end
    return true
end

function M.record(host)
    return record(host,os.time())
end

function M.suspend(host)
    local ctx=host._native_home_resume
    M.cancel(host)
    -- Only passive recording can resume. A user's explicit open stays cancelled.
    if ctx and ctx.recording then host._native_home_resume_after_wake=ctx end
end

function M.resume(host)
    local ctx=host._native_home_resume_after_wake
    host._native_home_resume_after_wake=nil
    if not ctx or host._native_home_resume or not same_reader(host,ctx) then return false end
    return record(host,ctx.at)
end

local function open(host,book,id,view,view_current,detail)
    if not M.can_resume(host,book,id) or type(view_current)~='function' then return false end
    local scope=host.settings:get_auth_scope();local owner=account(host,scope)
    local pointer=book.native_home_resume
    M.cancel(host)
    local ctx={scope=scope,owner=owner,view=view,session=host._reader_session_gen or 0,pointer=pointer}
    host._native_home_resume=ctx
    local function current()
        return host._native_home_resume==ctx and not host._weread_suspended
            and (detail and host._book_detail_view==view or not detail and host.shelf_view==view) and view_current()
            and (host._reader_session_gen or 0)==ctx.session and account(host,scope)==owner
    end
    local function fail()
        local live=current();M.cancel(host)
        if live then host:showInfo(detail and _('The saved E-Ink chapter changed or could not be verified. Choose a saved chapter instead.')
            or _('The saved E-Ink chapter changed or could not be verified. Open the book details to choose a chapter.')) end
    end
    local w=worker(host)
    if not w then fail();return false end
    host:showBusy(_('Checking saved E-Ink chapter...'),function() M.cancel(host) end);ctx.busy=host.busy_message
    local ok,started=pcall(w.start,w,function()
        if not Cache.valid_entry(pointer.entry,id,scope.vid) then return {error='invalid'} end
        return Cache.open(host.settings,scope.vid,id,pointer.entry,current) or {error='invalid'}
    end,function(value)
        if not current() then if host._native_home_resume==ctx then M.cancel(host) end;return end
        local latest=host.settings:get_book(id)
        if not M.can_resume(host,latest,id) or not same(pointer,latest.native_home_resume)
            or type(value)~='table' or not Path.contains(host.settings,value.path)
            or value.file_id~=pointer.entry.file_id or value.book_version~=pointer.entry.book_version
            or value.source_sha256~=pointer.entry.source_sha256 then fail();return end
        local path=value.path;M.cancel(host);host:openFile(path)
    end)
    if not ok or not started then fail();return false end
    return true
end

function M.open(host,book,id,view,view_current)
    return open(host,book,id,view,view_current,false)
end

function M.open_detail(host,book,id,view)
    return open(host,book,id,view,function() return host._book_detail_view==view end,true)
end
return M

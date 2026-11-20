-- Navigate a verified combined EPUB to its actual spine member.
local Dom=require('weread.lib.source_dom')
local Claims=require('weread.lib.chapter_cache_claim')
local _=require('weread.lib.plugin_util').tr
local M={}
local function stat(path)
    return require('libs/libkoreader-lfs').symlinkattributes(path)
end
local function same_file(a,b)
    return a and b and a.mode=='file' and b.mode=='file' and a.dev==b.dev and a.ino==b.ino
        and a.size==b.size and a.modification==b.modification
end
local function account(host)
    if not host.library_db or type(host.library_db.accountKey)~='function' then return nil end
    return host.library_db:accountKey()
end
local function valid(guard)
    local ok,value=pcall(guard)
    return ok and value==true
end
local function failure(host)
    if host and type(host.showInfo)=='function' then
        host:showInfo(_('Could not verify this chapter in the combined book. Download the chapter again.'))
    end
end
local function local_only_notice(host)
    if host and type(host.showTransientInfo)=='function' then
        host:showTransientInfo(_('This combined file cannot be verified against the complete book. Progress sync is paused for this reading session; the previous position is kept.'),4)
    end
end
local function unverified_catalog(host,document,book_id,proof)
    local ok,complete=pcall(function()
        local book=host.settings:get_book(book_id)
        if not book then return false end
        local catalog=host:ensureChaptersLoaded(book)
        return Claims.document_complete(proof,document,book_id,catalog)
    end)
    return not ok or complete~=true
end
local function move(reader,target)
    local doc=reader and reader.document
    if not doc or type(target)~='string' or not doc:isXPointerInDocument(target)
        or not reader.rolling or type(reader.rolling.onGotoXPointer)~='function' then return false end
    if reader.link and type(reader.link.addCurrentLocationToStack)=='function' then
        reader.link:addCurrentLocationToStack()
    end
    local ok=pcall(reader.rolling.onGotoXPointer,reader.rolling,target)
    return ok and doc:isXPointerInCurrentPage(target)
end

function M.open(host,book,chapter,path,current,proof,partial)
    if not valid(current) then return false end
    if type(proof)~='table' or type(proof.opf_hash)~='string' then return false end
    local before=stat(path)
    if not before or before.mode~='file' then failure(host);return false end
    local ui=host.ui;local document=ui and ui.document
    local book_id=tostring(book.book_id or book.bookId or '')
    local uid=tostring(chapter.chapterUid or chapter.chapterId or '')
    local session=host._reader_session_gen or 0
    local epoch=host.settings:get('auth_epoch',0)
    local scope=host.settings.get_auth_scope and host.settings:get_auth_scope()
    local owner=account(host)
    local function same_account(target)
        if not target or not target.settings or target.settings:get('auth_epoch',0)~=epoch or account(target)~=owner then return false end
        if scope then return target.settings.auth_scope_matches and target.settings:auth_scope_matches(scope) end
        return not target.settings.get_auth_scope or not target.settings:get_auth_scope()
    end
    if document and document.file==path then
        local target=Dom.chapter_start(document,book_id,uid,proof)
        if not target then failure(host);return false end
        if not valid(current) then return false end
        host:closeWeReadUI()
        if host.ui~=ui or ui.document~=document or document.file~=path
            or (host._reader_session_gen or 0)~=session or not same_account(host)
            or not same_file(before,stat(path)) then return false end
        local sync=host.progress_sync
        partial=partial or unverified_catalog(host,document,book_id,proof)
            or sync and sync.file_resume and sync.file_resume.preserve_only or false
        local frame
        if sync and partial then
            frame=sync:begin_file_resume({partial_combined=true})
            if not frame then failure(host);return false end
        elseif sync then sync:begin_local_navigation() end
        local ok=move(ui,target)
        if frame and not sync:finish_file_resume(frame,ok) then ok=false end
        if not ok then failure(host) end
        if ok and partial then local_only_notice(host) end
        return ok
    end
    if not valid(current) then return false end
    if host.progress_sync then
        host.progress_sync:checkpoint_local('chapter_selection_departure')
        host.progress_sync:begin_file_resume_departure()
    end
    local used=false
    host:openFile(path,function(reader)
        if used then return false end
        used=true
        local next_host=reader and reader.weread
        if not reader or not reader.document or reader.document.file~=path or not next_host
            or (host._reader_session_gen or 0)~=session+(document and 1 or 0)
            or not same_account(host) or not same_account(next_host) or not same_file(before,stat(path))
            or tostring(next_host:detectWeReadBook() or '')~=book_id then return false end
        local sync=next_host.progress_sync
        if not sync or sync.navigation_generation~=0 or sync.pending_jump or sync.verified
            or next_host.cloud_source_request then return false end
        local target=Dom.chapter_start(reader.document,book_id,uid,proof)
        if not target then failure(next_host);return false end
        local local_only=partial or unverified_catalog(next_host,reader.document,book_id,proof)
        local frame=sync:begin_file_resume(local_only and {partial_combined=true} or nil)
        if not frame then failure(next_host);return false end
        local applied=move(reader,target)
        if not sync:finish_file_resume(frame,applied) or not applied then failure(next_host);return false end
        if local_only then local_only_notice(next_host) end
        return true
    end,book)
    return true
end
return M

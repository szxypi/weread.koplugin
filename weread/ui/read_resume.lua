-- Transfer a local original-text point between different EPUB packages.
-- Only bound metadata is read here; the existing navigator verifies raw bytes
-- in its independent worker before touching the native document.
local Access=require('weread.lib.read_access')
local Context=require('weread.lib.source_context')
local Reading=require('weread.ui.book_reading')
local Source=require('weread.lib.position_source')
local _=require('weread.lib.plugin_util').tr
local M={}
local fields={'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}
local function now() return os.time() end
local function account(host)
    if host.library_db and host.library_db.accountKey then return host.library_db:accountKey() end
    return host.progress_sync and host.progress_sync:_account_key()
end
local function hash(value) return type(value)=='string' and #value==64 and value:match('^[a-f0-9]+$')~=nil end
local function mode(host) return host.ui and host.ui.view and host.ui.view.view_mode or 'page' end
local function marker(host) return host.ui and host.ui.rolling and host.ui.rolling.xpointer end
function M.position(value,id)
    if type(id)~='string' or Access.display_book_id(id)~=id or type(value)~='table' or value.book_id~=id or not Source.is_coordinate_basis(value.basis) or value.upload_verified~=false
        or type(value.chapter_uid)~='string' or #value.chapter_uid==0 or #value.chapter_uid>256 or value.chapter_uid:find('[%z%c]')
        or type(value.chapter_offset)~='number' or value.chapter_offset<0 or value.chapter_offset%1~=0 or value.chapter_offset>Source.MAX_BYTES*8
        or not hash(value.file_id) or not hash(value.raw_sha256) or type(value.book_version)~='number'
        or value.book_version<0 or value.book_version%1~=0 or value.book_version>2147483647
        or type(value.render_path)~='string' or #value.render_path==0 or #value.render_path>1024 or value.render_path:find('[%z%c]') then return nil end
    local result={};for _i,key in ipairs(fields) do result[key]=value[key] end
    return result
end
function M.from_book(book,owner)
    local id=type(book)=='table' and Access.display_book_id(book.book_id or book.bookId)
    if not id then return nil end
    for _i,position in ipairs(Reading.local_positions(book,owner)) do
        if next(position) then
            local source=M.position(position.source_position,id)
            if source and (position.chapter_uid==nil or tostring(position.chapter_uid)==source.chapter_uid) then return source,position.source_view end
            return nil -- A newer local point without source data must not revive an older point.
        end
    end
end
function M.bind(document,position,view,owner,frame)
    position=M.position(position,type(position)=='table' and position.book_id)
    if not position then return nil,'position_unavailable' end
    local snapshot=Source.document_metadata(document,position.book_id,position.chapter_uid)
    if not snapshot then return nil,'chapter_unavailable' end
    local record=snapshot.record
    if record.raw_sha256~=position.raw_sha256 or Source.coordinate_basis(record.format)~=position.basis then return nil,'source_changed' end
    if record.file_id==position.file_id then
        if record.book_version~=position.book_version or record.render_path~=position.render_path
            or not require('weread.lib.source_view').matches(view,frame,owner,position) then return nil,'same_file' end
    end
    local target={};for _i,key in ipairs(fields) do target[key]=position[key] end
    target.file_id,target.render_path,target.book_version=record.file_id,record.render_path,record.book_version
    return target
end
function M.cancel(host)
    host._read_resume_token=nil
end
function M.on_close(host)
    local token=host._read_resume_token
    if token and not token.dispatched then M.cancel(host) end
end
function M.view_changed(host)
    local token=host._read_resume_token
    if not token or token.dispatched then return end
    local document=host.ui and host.ui.document
    if document~=token.document or marker(host)~=token.marker
        or not Context.same_location(token.location,Context.location(document,mode(host))) then M.cancel(host) end
end
function M.navigation_cancelled(host,job)
    local active=host._read_resume_active
    if active and active.job==job then
        host._read_resume_active=nil
        pcall(host.progress_sync.finish_file_resume,host.progress_sync,active.frame,false)
    end
end
local function notify(host)
    if host.showTransientInfo then host:showTransientInfo(_('Could not restore the previous text position. This file’s local position is kept.'),4) end
end
local function finish(host,frame,applied)
    local ok,saved=pcall(host.progress_sync.finish_file_resume,host.progress_sync,frame,applied)
    if not ok and host.showInfo then
        host:showInfo(_('Reading position opened, but it could not be saved. Check storage before continuing.'))
    end
    return ok and saved
end
function M.open(host,path,book,dispatch)
    M.cancel(host)
    -- CB_ uses the same archive-bound local receipts; this does not authorize
    -- cloud positions or change the separate upload identity checks.
    local id=type(book)=='table' and Access.display_book_id(book.book_id or book.bookId)
    local owner=account(host)
    local auth=host.settings and host.settings.get_auth_scope and host.settings:get_auth_scope()
    if not id or not owner or not auth or not host.settings:auth_scope_matches(auth) then dispatch();return true end
    local document=host.ui and host.ui.document
    if document and document.file==path then dispatch();return true end
    local token={document=document,location=document and Context.location(document,mode(host)),marker=marker(host),
        owner=owner,auth=auth,session=host._reader_session_gen or 0,started=now(),path=path,
        navigation=host.progress_sync and host.progress_sync.navigation_generation}
    host._read_resume_token=token
    local function valid_parent(closed)
        local elapsed=now()-token.started
        if host._read_resume_token~=token or elapsed<0 or elapsed>120 or account(host)~=owner
            or not host.settings:auth_scope_matches(auth)
            or token.navigation~=nil and host.progress_sync.navigation_generation~=token.navigation then return false end
        if closed then return (host._reader_session_gen or 0)==token.session+(document and 1 or 0) end
        return (host.ui and host.ui.document)==document and (host._reader_session_gen or 0)==token.session
            and (not document or (marker(host)==token.marker and Context.same_location(token.location,Context.location(document,mode(host)))))
    end
    local function launch(position,view)
        if not valid_parent(false) then return end
        position=M.position(position,id)
        if not position then host._read_resume_token=nil;dispatch();return end
        token.dispatched=true
        local used=false
        dispatch(function(reader)
            if used then return false end
            used=true
            local valid=valid_parent(true)
            if host._read_resume_token==token then host._read_resume_token=nil end
            local next_host=type(reader)=='table' and reader.weread
            local sync=next_host and next_host.progress_sync
            local doc=type(reader)=='table' and reader.document
            if not valid or not next_host or not sync or next_host==host or not doc or not next_host.ui
                or doc~=next_host.ui.document or doc.file~=path
                or account(next_host)~=owner or not next_host.settings:auth_scope_matches(auth)
                or tostring(next_host:detectWeReadBook() or '')~=id or sync.navigation_generation~=0
                or sync.pending_jump or sync.verified or next_host.cloud_source_request then return false end
            local viewport=view and sync._viewport and sync:_viewport(doc)
            local target,reason=M.bind(doc,position,view,owner,viewport)
            if not target and reason~='source_changed' then return false end
            local started,frame=pcall(sync.begin_file_resume,sync)
            if not started or not frame then notify(next_host);return false end
            if not target then finish(next_host,frame,false);notify(next_host);return false end
            local active={frame=frame};next_host._read_resume_active=active
            local called,opened=pcall(next_host.openSourcePosition,next_host,target,function(applied)
                if next_host._read_resume_active~=active then return end
                next_host._read_resume_active=nil
                if finish(next_host,frame,applied~=nil) and not applied then notify(next_host) end
            end)
            if not called or not opened then
                if next_host._read_resume_active==active then next_host._read_resume_active=nil end
                finish(next_host,frame,false);notify(next_host);return false
            end
            if next_host._read_resume_active==active then active.job=next_host.source_navigation.job end
            return true
        end)
    end
    local live=host.progress_sync and document and tostring(host:detectWeReadBook() or '')==id
    if live and host.source_position then
        if not host.source_position:current() and host.showTransientInfo then
            host:showTransientInfo(_('Preparing book for reading...'),1)
        end
        local function prepared(position)
            if not valid_parent(false) then return end
            local saved=pcall(host.progress_sync.checkpoint_local,host.progress_sync,'file_resume_prepare',position)
            if not saved then launch(nil);return end
            if M.position(position,id) then
                local paused=pcall(host.progress_sync.begin_file_resume_departure,host.progress_sync)
                if not paused then launch(nil);return end
                token.navigation=host.progress_sync.navigation_generation
            end
            launch(position)
        end
        local called=pcall(host.source_position.check,host.source_position,prepared)
        if not called and valid_parent(false) then launch(nil) end
    else
        launch(M.from_book(host.settings:get_book(id) or book,owner))
    end
    return true
end
return M

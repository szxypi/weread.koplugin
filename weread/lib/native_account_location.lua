-- Account-specific native EPUB locations stored alongside KOReader settings.
-- Unknown legacy locations remain untouched until their ownership is proven.
local Identity=require('weread.lib.book_file_identity')
local Access=require('weread.lib.read_access')
local SourceView=require('weread.lib.source_view')
local ReaderPosition=require('weread.lib.reader_position')
local _=require('weread.lib.i18n').tr
local Crypto=require('weread.lib.crypto')
local lfs=require('libs/libkoreader-lfs')
local M={}
local KEY='weread_account_locations'
local function hash(value,n) return type(value)=='string' and #value==n and value:match('^[a-f0-9]+$')~=nil end
local function pointer(value) return type(value)=='string' and #value>0 and #value<=4096 and not value:find('[%z%c]') end
local function owner(value) return value=='anonymous' or hash(value,20) end
local function stat(path)
    local ok,value=pcall(lfs.attributes,path)
    if not ok or type(value)~='table' or value.mode~='file' or type(value.size)~='number'
        or value.size<0 or value.size~=value.size or type(value.modification)~='number'
        or value.modification~=value.modification then return end
    return {size=value.size,mtime=value.modification}
end
local function same_stat(a,b) return a and b and a.size==b.size and a.mtime==b.mtime end
local function copy(value)
    if type(value)~='table' then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
local function map_valid(value,id)
    if type(value)~='table' or value.schema~=1 or value.book_id~=id or not hash(value.file_id,64)
        or type(value.entries)~='table' or type(value.file_size)~='number' or value.file_size<0
        or type(value.file_mtime)~='number' or value.file_size~=value.file_size or value.file_mtime~=value.file_mtime then return false end
    local count=0
    for key,entry in pairs(value.entries) do
        count=count+1
        if count>64 or not owner(key) or type(entry)~='table' or not pointer(entry.xpointer) then return false end
        for name in pairs(entry) do if name~='xpointer' then return false end end
    end
    if value.legacy~=nil and (type(value.legacy)~='table' or not pointer(value.legacy.xpointer)) then return false end
    if value.legacy then for key in pairs(value.legacy) do if key~='xpointer' then return false end end end
    for key in pairs(value) do
        if key~='schema' and key~='book_id' and key~='file_id' and key~='entries' and key~='legacy'
            and key~='file_size' and key~='file_mtime' then return false end
    end
    return true
end
M.map_valid=map_valid
local function cached(book,path)
    if type(book)~='table' or type(path)~='string' then return false end
    if book.cached_file==path or book.cached_full_book==path then return true end
    for _uid,filename in pairs(type(book.cached_chapters)=='table' and book.cached_chapters or {}) do
        if filename==path then return true end
    end
    return false
end
local function scope(host)
    local key=host.library_db and host.library_db.accountKey and host.library_db:accountKey()
    return key or 'anonymous'
end
local function visible(host,document,value)
    local view=host.ui and host.ui.view
    if view and view.view_mode=='scroll' then
        local get_height=host.progress_sync and host.progress_sync.get_viewport_height
        local ok,height=pcall(function() return get_height and get_height() or view.dimen and view.dimen.h end)
        if not ok or type(height)~='number' or height<=0 then return false end
        local frame=ReaderPosition.snapshot(document,'scroll',height)
        return ReaderPosition.contains_anchor(document,frame,value)
    end
    local ok,result=pcall(document.isXPointerInCurrentPage,document,value)
    return ok and result==true
end
local function current_pointer(host,document)
    local view=host.ui and host.ui.view
    if view and view.view_mode=='scroll' then
        local dimen=view.dimen
        if type(dimen)~='table' or type(dimen.w)~='number' or type(dimen.h)~='number'
            or dimen.w<=0 or dimen.h<=0 then return end
        -- CREngine's scroll getXPointer can refer to an earlier page origin.
        -- Select the first visible text instead and independently check it is
        -- within the current viewport; image-only views cannot be claimed.
        local ok,result=pcall(document.getTextFromPositions,document,{x=0,y=0},
            {x=dimen.w-1,y=dimen.h-1},true)
        local value=ok and type(result)=='table' and result.pos0
        if pointer(value) and visible(host,document,value) then return value end
        return
    end
    local ok,value=pcall(document.getXPointer,document)
    if ok and pointer(value) and visible(host,document,value) then return value end
end
local function auth_current(host,session)
    return session.auth and host.settings and host.settings.auth_scope_matches
        and host.settings:auth_scope_matches(session.auth)
end
local function claims_valid(claims,id,account)
    if claims==nil then return true end
    if type(claims)~='table' then return false end
    local count=0
    for key,value in pairs(claims) do
        count=count+1
        if count>128 or not hash(key,64) or type(value)~='table' or value.schema~=1
            or value.book_id~=id or value.owner~=account or value.path_hash~=key or not hash(value.file_id,64)
            or not pointer(value.xpointer) or type(value.file_size)~='number' or value.file_size<0
            or value.file_size~=value.file_size or type(value.file_mtime)~='number'
            or value.file_mtime~=value.file_mtime then return false end
        for field in pairs(value) do
            if field~='schema' and field~='book_id' and field~='owner' and field~='path_hash'
                and field~='file_id' and field~='xpointer' and field~='file_size' and field~='file_mtime' then return false end
        end
    end
    return true
end
local function saved_claim(host,session,identity)
    if not auth_current(host,session) then return end
    local book=host.settings:get_book(session.id)
    local claims=book and book.native_location_claims
    if not claims_valid(claims,session.id,session.owner) or not claims then return end
    local key=Crypto.sha256_hex(session.path);local selected=claims[key]
    if selected and selected.file_id==identity.file_id
        and same_stat(session.stat,{size=selected.file_size,mtime=selected.file_mtime}) then return selected end
end
function M.load(host,config,document)
    host._native_account_location=nil
    if not config or not document or not host.settings or not host.settings.get_book then return end
    local id=host:detectWeReadBook();id=Access.display_book_id(id)
    local account=scope(host)
    if not id or not owner(account) then return end
    local book=host.settings:get_book(id)
    if not cached(book,document.file) then return end
    local current_stat=stat(document.file)
    if not current_stat then return end
    local raw=config:readSetting(KEY)
    if raw~=nil and not map_valid(raw,id) then return end
    if raw and not same_stat(current_stat,{size=raw.file_size,mtime=raw.file_mtime}) then return end
    local original=config:readSetting('last_xpointer')
    if original~=nil and not pointer(original) then return end
    local old_percent=config:readSetting('last_percent')
    local old_page=config:readSetting('last_page')
    local session={id=id,owner=account,document=document,config=config,original=original,map=raw and copy(raw),
        original_percent=old_percent,original_page=old_page,book=book,stat=current_stat,path=document.file,
        auth=host.settings.get_auth_scope and host.settings:get_auth_scope()}
    host._native_account_location=session
    if raw then
        -- Identity is only safe to inspect after ReaderReady. Start at the
        -- beginning, then apply a verified account pointer before sync starts.
        config:delSetting('last_xpointer');config:delSetting('last_percent');config:delSetting('last_page')
    end
end
local function proof(session,identity)
    local point=session.book and session.book.last_local_position
    local source=type(point)=='table' and point.source_position
    local view=type(point)=='table' and point.source_view
    return hash(session.owner,20) and type(source)=='table' and source.book_id==session.id
        and source.file_id==identity.file_id and type(view)=='table' and type(view.view)=='table'
        and view.view.xpointer==session.original and SourceView.matches(view,view.view,session.owner,source)
end
function M.ready(host,id)
    local session=host._native_account_location
    if not session or session.id~=id or not host.ui or host.ui.document~=session.document then return end
    local current=scope(host)
    if not owner(current) then return end
    if current~=session.owner then
        local book=host.settings:get_book(id)
        if not cached(book,session.path) then return end
        session.owner=current;session.book=book
        session.auth=host.settings.get_auth_scope and host.settings:get_auth_scope()
    end
    local identity=Identity.read_document(session.document,id)
    local function restore_legacy(force)
        if (session.map or force) and session.original and host.ui.rolling then
            local ok,valid=pcall(session.document.isXPointerInDocument,session.document,session.original)
            if ok and valid then pcall(host.ui.rolling.onGotoXPointer,host.ui.rolling,session.original) end
        elseif (session.map or force) and type(session.original_percent)=='number' and session.original_percent>=0
            and session.original_percent<=1 and host.ui.rolling then
            pcall(host.ui.rolling.onGotoPercent,host.ui.rolling,session.original_percent*100)
        elseif (session.map or force) and type(session.original_page)=='number' and session.original_page>=1
            and session.original_page%1==0 and host.ui.paging then
            pcall(host.ui.paging.onGotoPage,host.ui.paging,session.original_page)
        end
    end
    if not hash(identity.file_id,64) or identity.book_id~=id then restore_legacy();return end
    session.file_id=identity.file_id
    if not session.map then
        local claimed=saved_claim(host,session,identity)
        if claimed and host.ui.rolling then
            local ok,valid=pcall(session.document.isXPointerInDocument,session.document,claimed.xpointer)
            if ok and valid then
                local moved,result=pcall(host.ui.rolling.onGotoXPointer,host.ui.rolling,claimed.xpointer)
                if moved and result~=false and visible(host,session.document,claimed.xpointer) then
                    session.allowed=true;return
                end
            end
        end
        if claimed then
            restore_legacy(true)
            if host.showTransientInfo then host:showTransientInfo(_('Could not restore the saved local reading position.'),3) end
        end
        session.allowed=session.original==nil and session.original_percent==nil and session.original_page==nil
            or proof(session,identity)
        return
    end
    if session.map.file_id~=identity.file_id then
        -- File bytes changed without a visible stat change. Keep the native
        -- legacy behavior, and never replace the old account map.
        restore_legacy()
        return
    end
    local entry=session.map.entries[session.owner]
    if not entry then session.allowed=true;return end
    local ok,valid=pcall(session.document.isXPointerInDocument,session.document,entry.xpointer)
    if not ok or not valid or not host.ui.rolling then restore_legacy();return end
    local moved,result=pcall(host.ui.rolling.onGotoXPointer,host.ui.rolling,entry.xpointer)
    if moved and result~=false then session.allowed=true else restore_legacy() end
end

-- Explicitly bind the page the reader is displaying, without changing the
-- cloud position or rewriting KOReader's shared sidecar at this point.
function M.can_claim(host)
    local session=host._native_account_location
    if not session or session.map or session.allowed or not hash(session.owner,20) or not session.file_id
        or scope(host)~=session.owner or not auth_current(host,session) or not host.ui
        or host.ui.document~=session.document or host.ui.doc_settings~=session.config
        or not same_stat(session.stat,stat(session.path)) or not host.settings.patch_reading_state then return false end
    local book=host.settings:get_book(session.id)
    return cached(book,session.path) and claims_valid(book.native_location_claims,session.id,session.owner)
end
function M.claim(host)
    if not M.can_claim(host) then return false end
    local session=host._native_account_location
    local value=current_pointer(host,session.document)
    if not value then return false end
    local book=host.settings:get_book(session.id)
    local claims=copy(book.native_location_claims or {})
    local key=Crypto.sha256_hex(session.path)
    if not claims[key] then
        local count=0;for _key in pairs(claims) do count=count+1 end
        if count>=128 then return false end
    end
    local record={schema=1,book_id=session.id,owner=session.owner,path_hash=key,file_id=session.file_id,
        xpointer=value,file_size=session.stat.size,file_mtime=session.stat.mtime}
    claims[key]=record
    local called,saved=pcall(host.settings.patch_reading_state,host.settings,session.id,{native_location_claims=claims})
    if not called or not saved or not M.can_claim(host) then return false end
    local actual=host.settings:get_book(session.id)
    local persisted=actual and actual.native_location_claims
    if not claims_valid(persisted,session.id,session.owner) or not persisted or not persisted[key] then return false end
    for field,expected in pairs(record) do if persisted[key][field]~=expected then return false end end
    session.allowed=true
    return true
end
function M.before_close(host)
    local session=host._native_account_location
    local view=host.ui and host.ui.view
    if session and session.allowed and view and view.view_mode=='scroll'
        and host.ui.document==session.document and scope(host)==session.owner then
        -- ReaderUI can close its document before SaveSettings is delivered.
        -- Capture a visible scroll anchor while the engine is still alive.
        session.closing_pointer=current_pointer(host,session.document)
    end
end
function M.save(host)
    local session=host._native_account_location
    if not session or not session.allowed or not session.file_id or scope(host)~=session.owner
        or not host.ui or host.ui.doc_settings~=session.config or not same_stat(session.stat,stat(session.path)) then return end
    local view=host.ui.view
    local value
    if view and view.view_mode=='scroll' then
        value=host.ui.document==session.document and current_pointer(host,session.document) or session.closing_pointer
    else value=session.config:readSetting('last_xpointer') end
    if not pointer(value) then return end
    local map=session.map and copy(session.map) or {schema=1,book_id=session.id,file_id=session.file_id,
        file_size=session.stat.size,file_mtime=session.stat.mtime,entries={}}
    if map.file_id~=session.file_id then return end
    if not session.map and pointer(session.original) then map.legacy={xpointer=session.original} end
    if not map.entries[session.owner] then
        local count=0;for _key in pairs(map.entries) do count=count+1 end
        if count>=64 then return end
    end
    map.entries[session.owner]={xpointer=value}
    session.config:saveSetting(KEY,map);session.map=map
end
return M

-- Local display choices; no translation generation, HTTP, or EPUB rewriting.
local Model=require('weread.lib.translation')
local Archive=require('weread.lib.translation_archive')
local Identity=require('weread.lib.book_file_identity')
local Position=require('weread.lib.reader_position')
local Crypto=require('weread.lib.crypto')
local UIManager=require('ui/uimanager')
local PluginUtil=require('weread.lib.plugin_util')
local _,T=PluginUtil.tr,PluginUtil.T
local M={}
local pending
local ORIGINAL='.wr-translation { display: none !important; }'
local function account(host) return host.library_db and host.library_db:accountKey() end
local function stat(path)
    local ok,value=pcall(function() return require('libs/libkoreader-lfs').attributes(path) end)
    if not ok or type(value)~='table' or value.mode~='file' then return nil end
    return {size=value.size,mtime=value.modification,ino=value.ino,dev=value.dev}
end
local function equal(a,b)
    return a and b and a.size==b.size and a.mtime==b.mtime and a.ino==b.ino and a.dev==b.dev
end
local function document(host) return host.ui and host.ui.document end
local function scope(host)
    local doc=document(host);local id=host:detectWeReadBook()
    if not doc or not id or tostring(id):sub(1,7)=='MP_WXS_' or type(doc.file)~='string' or not doc.file:lower():match('%.epub$') then return nil end
    local attributes=stat(doc.file)
    if not attributes then return nil end
    return {document=doc,file=doc.file,book_id=tostring(id),account=account(host),session=host._reader_session_gen,stat=attributes}
end
local function current(host,owner)
    return owner and document(host)==owner.document and owner.document.file==owner.file
        and tostring(host:detectWeReadBook() or '')==owner.book_id and account(host)==owner.account
        and host._reader_session_gen==owner.session and equal(stat(owner.file),owner.stat)
end
local function preference(host)
    local value=host.ui.doc_settings and host.ui.doc_settings:readSetting('weread_translation')
    if type(value)~='table' or value.schema~=1 or value.book_id~=tostring(host:detectWeReadBook() or '') then return 'original',100 end
    return Model.normalize_mode(value.mode),Model.normalize_font_scale(value.scale)
end
local function close_menu(host)
    local menu=host._translation_menu;host._translation_menu=nil
    if menu then UIManager:close(menu) end
end
function M.cancel(host,keep_transfer)
    close_menu(host)
    local job=host.translation_job;host.translation_job=nil
    if job then
        if host.translation_worker then host.translation_worker:cancel() end
        if job.busy and host.busy_message==job.busy then host:closeBusy() end
    end
    if pending and not keep_transfer and (pending.host==host or pending.claimed==host) then pending=nil end
end
local function install(host)
    local style=host.ui.styletweak
    if not style or type(style.getCssText)~='function' then return false end
    if host._translation_style and host._translation_style.style==style then return true end
    local base=style.getCssText
    local wrapper=function(instance)
        local text=base(instance) or ''
        return text..'\n'..(host._translation_css or ORIGINAL)
    end
    host._translation_style={style=style,base=base,wrapper=wrapper}
    style.getCssText=wrapper
    return true
end
local function attach(host,profile,mode,scale)
    local css=profile and Model.css(profile,mode,scale)
    if mode~='original' and not css then mode='original' end
    host._translation_profile=profile
    host._translation_css=mode=='original' and ORIGINAL or css
    host._translation_mode,host._translation_scale=mode,scale
    return install(host)
end
local function transfer_current(host,value)
    local age=os.time()-value.started
    return pending==value and host~=value.host and age>=0 and age<=120 and document(host)
        and document(host).file==value.owner.file and account(host)==value.owner.account
        and tostring(host:detectWeReadBook() or '')==value.owner.book_id
        and value.host._reader_session_gen==value.owner.session+1 and equal(stat(value.owner.file),value.owner.stat)
end
function M.restore(host)
    local owner=scope(host)
    if not owner or not host.ui.typeset or not host.ui.typeset.css then return end
    host._translation_open_stat=owner.stat
    local mode,scale=preference(host)
    local profile
    if pending and transfer_current(host,pending) and pending.mode==mode and pending.scale==scale then
        profile=pending.profile;pending.claimed=host;host._translation_incoming=pending
    elseif mode~='original' then profile=Archive.inspect(owner.file,owner.book_id) end
    if not attach(host,profile,mode,scale) then return end
    if mode~='original' and host._translation_mode=='original' then host._translation_restore_error=true end
    host.ui.document:setStyleSheet(host.ui.typeset.css,host.ui.styletweak:getCssText())
end
local function bound(host,profile)
    if type(profile)~='table' or profile.schema~=1 or profile.book_id~=tostring(host:detectWeReadBook() or '')
        or type(profile.chapters)~='table' or #profile.chapters<1 or #profile.chapters>Archive.MAX_SPINE
        or type(profile.opf_path)~='string' or type(profile.opf_sha256)~='string'
        or type(profile.blocks)~='number' or profile.blocks<0 or profile.blocks>2000000 or profile.blocks%1~=0
        or type(profile.pairs)~='number' or profile.pairs<0 or profile.pairs>Archive.MAX_PAIRS or profile.pairs%1~=0 then return false end
    for index,chapter in ipairs(profile.chapters) do
        if type(chapter)~='table' or chapter.fragment_index~=index or type(chapter.pairs)~='table' or type(chapter.tags)~='table' then return false end
    end
    local doc=document(host)
    local identity=Identity.read_document(doc,profile.book_id)
    if profile.file_id~='' and identity.file_id~=profile.file_id then return false end
    local ok,raw=pcall(doc.getDocumentFileContent,doc,profile.opf_path)
    return ok and type(raw)=='string' and #raw<=Archive.MAX_META and Crypto.sha256_hex(raw)==profile.opf_sha256
end
function M.pre_render(host)
    local profile=host._translation_profile
    if profile and (not equal(host._translation_open_stat,stat(document(host).file)) or not bound(host,profile)) then
        host._translation_restore_error=true;host._translation_profile=nil;host._translation_mode='original';host._translation_css=ORIGINAL
        pending=nil
        document(host):setStyleSheet(host.ui.typeset.css,host.ui.styletweak:getCssText())
    end
end
function M.reader_ready(host)
    if host.translation_job or host._translation_menu then M.cancel(host,host._translation_incoming~=nil) end
    local value=host._translation_incoming
    if value and transfer_current(host,value) and value.claimed==host and bound(host,value.profile) then
        -- Cancel the ordinary delayed open pull before the local display
        -- transition restores its paragraph. This grants no upload permission.
        if host.progress_sync then host.progress_sync:begin_cloud_source_navigation() end
    end
    if host._translation_restore_error then
        host:showTransientInfo(_('Could not verify the local translation. Reopen or download this book again.'),3)
    end
end
function M.document_close(host)
    local keep=pending and pending.host==host and pending.reloading==true
    M.cancel(host,keep)
    local wrapped=host._translation_style;host._translation_style=nil
    if wrapped and wrapped.style.getCssText==wrapped.wrapper then wrapped.style.getCssText=wrapped.base end
    host._translation_profile,host._translation_css=nil,nil
end
local function receive(reader,value)
    local host=reader and reader.weread
    if not host or not transfer_current(host,value) or value.claimed~=host or not bound(host,value.profile) then
        if pending==value then pending=nil end
        return false
    end
    pending=nil;host._translation_incoming=nil
    if not reader.document:isXPointerInDocument(value.target) or not Position.goto_xpointer(reader,value.target) then
        host:showInfo(_('Could not restore the corresponding paragraph. Your saved book and notes are kept.'));return false
    end
    if value.held and host.progress_sync then
        local snapshot=require('weread.lib.position_source').document_metadata(reader.document,value.owner.book_id,value.held.chapter_uid,value.held.render_path)
        if snapshot then host.progress_sync:retain_source_target(value.held,value.target,snapshot.metadata) end
    end
    if host.source_position then host.source_position:on_view_changed(true) end
    host:showTransientInfo(T(_('Reading language: %1'),Model.label(value.mode)),2)
    return true
end
function M.apply(host,mode,scale,profile,owner)
    owner=owner or scope(host)
    mode=Model.normalize_mode(mode);scale=Model.normalize_font_scale(scale)
    if not current(host,owner) or not bound(host,profile) then host:showInfo(_('The book changed. Open reading language again.'));return false end
    if mode~='original' and (profile.blocks==0 or mode=='translation' and not Model.translation_only_status(profile).available) then
        host:showInfo(_('This local book has no verified translation for that mode. Download its translated chapters first.'));return false
    end
    local ui=host.ui
    if not ui.rolling or not ui.doc_settings or type(ui.reloadDocument)~='function' or ui.rolling.rendering_state
        or host.read_report and host.read_report.job or host.downloader and (host.downloader._active_job or host.downloader._pending_start or host.downloader._scheduled_start) then
        host:showInfo(_('The reader is busy. Please try again shortly.'));return false
    end
    if (host._translation_mode or 'original')==mode and (host._translation_scale or 100)==scale then close_menu(host);return true end
    local ok,xp=pcall(ui.document.getXPointer,ui.document)
    if not ok or type(xp)~='string' or #xp>4096 then return false end
    local resolved,target=pcall(function()
        local normalized=ui.document.getNormalizedXPointer and ui.document:getNormalizedXPointer(xp) or xp
        local candidate=Model.remap_xpointer(profile,normalized,mode) or normalized
        if type(candidate)=='string' and #candidate<=4096 and ui.document:isXPointerInDocument(candidate) then return candidate end
    end)
    if not resolved or not target then host:showInfo(_('Could not restore the corresponding paragraph. Your saved book and notes are kept.'));return false end
    local previous=ui.doc_settings:readSetting('weread_translation')
    ui.doc_settings:saveSetting('weread_translation',{schema=1,book_id=owner.book_id,mode=mode,scale=scale})
    local saved,where=pcall(ui.doc_settings.flush,ui.doc_settings)
    if not saved or not where then
        ui.doc_settings:saveSetting('weread_translation',previous)
        host:showInfo(_('Could not save the reading language. Check storage and try again.'));return false
    end
    local held=host.progress_sync and host.progress_sync:current_source_target()
    host:closeWeReadUI()
    if not current(host,owner) then
        ui.doc_settings:saveSetting('weread_translation',previous);pcall(ui.doc_settings.flush,ui.doc_settings)
        return false
    end
    if host.progress_sync then host.progress_sync:begin_cloud_source_navigation() end
    if host.source_navigation then host.source_navigation:cancel() end
    if host.source_position then host.source_position:pause('translation') end
    local value={host=host,owner=owner,mode=mode,scale=scale,profile=profile,target=target,held=held,started=os.time(),reloading=true}
    pending=value
    local cache_path=ui.document.getCacheFilePath and ui.document:getCacheFilePath()
    local reloaded,err=pcall(ui.reloadDocument,ui,function()
        -- Only the native cache of this open document is discarded. The EPUB
        -- and its sidecar remain intact; new display styles get a fresh DOM.
        if type(cache_path)=='string' and cache_path~='' and cache_path~=owner.file then os.remove(cache_path) end
    end,true,function(next_reader) receive(next_reader,value) end)
    if not reloaded or err==false then
        if pending==value then pending=nil end
        if document(host)==owner.document then
            ui.doc_settings:saveSetting('weread_translation',previous);pcall(ui.doc_settings.flush,ui.doc_settings)
            if host.source_position then host.source_position:resume('translation') end
        end
        host:showInfo(_('Could not change the reading language. Reopen this book and try again.'))
        return false
    end
    return err~=false
end
local function show_choices(host,profile,owner)
    if not current(host,owner) then return end
    local scale=host._translation_scale or 100
    local status=Model.translation_only_status(profile)
    local items={}
    local menu
    local function choose(mode,value)
        return function()
            if host._translation_menu~=menu or not current(host,owner) then return end
            M.apply(host,mode,value,profile,owner)
        end
    end
    for _i,mode in ipairs({'original','bilingual','translation'}) do
        local available=mode=='original' or profile.blocks>0 and (mode~='translation' or status.available)
        items[#items+1]={text=Model.label(mode),mandatory=not available and _('Unavailable')
            or host._translation_mode==mode and _('Current') or '',callback=choose(mode,scale)}
    end
    items[#items+1]={text=T(_('Translation text size: %1%'),scale),callback=function()
        if host._translation_menu~=menu or not current(host,owner) then return end
        close_menu(host)
        local sizes={}
        for _i,value in ipairs({80,90,100,110,120,140,160,180}) do
            sizes[#sizes+1]={text=value..'%',callback=choose(host._translation_mode or 'original',value)}
        end
        menu=host:showList(_('Translation text size'),sizes);host._translation_menu=menu
    end}
    items[#items+1]={text=T(_('Verified translated blocks: %1; unpaired blocks kept: %2'),profile.blocks,status.unpaired),callback=function()
        if host._translation_menu~=menu or not current(host,owner) then return end
        host:showInfo(_('Only verified pairs hide their original text. Unpaired paragraphs, illustrations and links remain visible.'))
    end}
    menu=host:showList(_('Reading language'),items);host._translation_menu=menu
end
function M.show(host)
    host:closeWeReadUI()
    local owner=scope(host)
    if not owner then return false end
    if not equal(owner.stat,host._translation_open_stat) then host:showInfo(_('The book changed. Open reading language again.'));return false end
    local cached=host._translation_profile
    if cached and bound(host,cached) then show_choices(host,cached,owner);return true end
    local job={owner=owner,started=os.time()};host.translation_job=job
    host:showBusy(_('Checking local translations…\nTap or press a key to cancel.'),function() if host.translation_job==job then M.cancel(host) end end)
    job.busy=host.busy_message
    if not host.translation_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client,max_bytes=8*1024*1024} end)
        if not ok then M.cancel(host);host:showInfo(_('Could not verify the local translation. Reopen or download this book again.'));return false end
        host.translation_worker=worker
    end
    local launched,started=pcall(host.translation_worker.start,host.translation_worker,function()
        local profile,reason=Archive.inspect(owner.file,owner.book_id)
        return profile and {ok=true,profile=profile} or {error=reason}
    end,function(result)
        if host.translation_job~=job then return end
        local age=os.time()-job.started
        if not current(host,owner) or age<0 or age>120 then M.cancel(host);return end
        local valid=type(result)=='table' and result.ok==true and bound(host,result.profile)
        M.cancel(host)
        if not valid then host:showInfo(_('Could not verify the local translation. Reopen or download this book again.'));return end
        host._translation_profile=result.profile
        show_choices(host,result.profile,owner)
    end)
    if not launched or not started then M.cancel(host);host:showInfo(_('Could not verify the local translation. Reopen or download this book again.')) end
    return launched and started==true
end
return M

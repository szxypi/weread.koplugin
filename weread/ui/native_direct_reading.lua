-- Read E-Ink chapters through an isolated local-only reader, without using Web
-- position coordinates. Network and EPUB preparation run off the UI thread.
local UIManager=require('ui/uimanager')
local Access=require('weread.lib.native_read_access')
local Recovery=require('weread.lib.native_read_recovery')
local Protocol=require('weread.lib.native_position_protocol')
local Crypto=require('weread.lib.crypto')
local PluginUtil=require('weread.lib.plugin_util')
local _,T=PluginUtil.tr,PluginUtil.T
local M={}

local function capture(settings,store)
    local native=Access.capture(settings,store)
    if not native then return nil end
    return {native=native,base_revision=Crypto.sha256_hex(native.scope.vid..'\0'..tostring(native.scope.epoch))}
end
local function hash(value)
    return type(value)=='string' and #value==64 and value:match('^[a-f0-9]+$')~=nil
end
local function text(value,limit)
    return type(value)=='string' and #value<=limit and not value:find('[%z%c]')
        and require('weread.lib.protocol').utf8_substr(value,#value)==value
end
local function project(model,id)
    if type(model)~='table' or model.book_id~=id or not Protocol.integer(model.version,0,2147483647)
        or not hash(model.reading_digest) or type(model.reading_chapters)~='table'
        or #model.reading_chapters==0 or #model.reading_chapters>20000 then return nil end
    local count,seen,rows=0,{},{}
    for key in pairs(model.reading_chapters) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#model.reading_chapters then return nil end
        count=count+1
    end
    if count~=#model.reading_chapters then return nil end
    for index,row in ipairs(model.reading_chapters) do
        if type(row)~='table' or type(row.chapterUid)~='string' or Protocol.id(row.chapterUid)~=row.chapterUid
            or seen[row.chapterUid] or not text(row.title,2048) or type(row.downloadable)~='boolean'
            or row.chapterIdx~=nil and not Protocol.integer(row.chapterIdx,0,1000000) then return nil end
        seen[row.chapterUid]=true
        rows[index]={chapterUid=row.chapterUid,title=row.title,chapterIdx=row.chapterIdx,downloadable=row.downloadable,
            catalog_order=index,catalog_count=#model.reading_chapters}
    end
    for index,row in ipairs(rows) do
        row.catalog_prev=rows[index-1] and rows[index-1].chapterUid or nil
        row.catalog_next=rows[index+1] and rows[index+1].chapterUid or nil
    end
    return {book_id=id,version=model.version,reading_digest=model.reading_digest,chapters=rows}
end
M.project=project

function M.cancel(host)
    local ctx=host._native_direct_reading
    if not ctx then return end
    host._native_direct_reading=nil
    if host._native_direct_worker then host._native_direct_worker:cancel() end
    Recovery.cancel(host,ctx)
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
    ctx.busy=nil
    local menu=ctx.menu;ctx.menu=nil
    if menu then UIManager:close(menu) end
end

function M.start(host,book,view,options)
    if type(book)~='table' or not view or host._book_detail_view~=view then return false end
    local id=Protocol.id(book.book_id or book.bookId)
    if not id then return false end
    local online=host.isNetworkConnected and host:isNetworkConnected() or not host.isNetworkConnected and host:isNetworkOnline()
    local offline=not online or type(options)=='table' and options.cached==true
    local target=type(options)=='table' and options.target or nil
    if target~=nil and (offline or type(target)~='table' or type(target.uid)~='string'
        or Protocol.id(target.uid)~=target.uid or type(target.from_uid)~='string' or Protocol.id(target.from_uid)~=target.from_uid
        or not hash(target.catalog_sha256) or not Protocol.integer(target.book_version,0,2147483647)
        or not Protocol.integer(target.count,1,20000) or not Protocol.integer(target.order,1,target.count)
        or (target.direction~=1 and target.direction~=-1)) then return false end
    local scope=host.settings:get_auth_scope()
    if not scope or not host.settings:auth_scope_matches(scope) then
        host:showInfo(_('Sign in to the account that saved these E-Ink chapters.'))
        return false
    end
    local selected=not offline and capture(host.settings) or nil
    if not offline and (not selected or selected.native.renewal_pending) then
        host:showInfo(_('E-Ink authorization is required to read these chapters.'))
        return false
    end
    M.cancel(host)
    local title=text(book.title,2048) and book.title or id
    local author=text(book.author,2048) and book.author or ''
    local document=host.ui and host.ui.document
    local ctx={view=view,epoch=host.discovery_epoch or 0,session=host._reader_session_gen,document=document,
        file=document and document.file,account=host.library_db and host.library_db:accountKey(),selected=selected,
        book={book_id=id,title=title,author=author},scope=scope,offline=offline,target=target}
    host._native_direct_reading=ctx
    local function view_current()
        local now=host.ui and host.ui.document
        return host._native_direct_reading==ctx and host._book_detail_view==view
            and (host.discovery_epoch or 0)==ctx.epoch and host._reader_session_gen==ctx.session
            and now==ctx.document and (not now or now.file==ctx.file)
            and (not host.library_db or host.library_db:accountKey()==ctx.account)
            and host.settings:auth_scope_matches(ctx.scope)
    end
    local function current()
        return view_current() and (ctx.offline or Access.matches(host.settings,ctx.selected.native))
    end
    local function close_busy()
        if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
        ctx.busy=nil
    end
    local function fail(message)
        if host._native_direct_reading~=ctx then return end
        local live=view_current();M.cancel(host)
        if live then host:showInfo(_(message or 'Could not prepare the E-Ink chapter. Please try again.')) end
    end
    if not host._native_direct_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
            scheduler=UIManager,codec=host.client,max_bytes=8*1024*1024,timeout=180} end)
        if not ok then fail();return false end
        host._native_direct_worker=worker
    end
    local launch
    local function renew()
        local started=Recovery.start(host,ctx,ctx.selected,{capture=capture,is_current=view_current,
            stale=function() if host._native_direct_reading==ctx then M.cancel(host) end end,
            complete=function(ok,fresh)
                ctx.selected=fresh
                if not ok then fail('E-Ink authorization expired. Please authorize again.');return end
                launch()
            end})
        if not started then fail('E-Ink authorization expired. Please authorize again.') end
    end
    local function show_catalog(catalog)
        close_busy()
        local items={}
        for _index,row in ipairs(catalog.chapters) do
            local chapter=row
            local label=chapter.title~='' and chapter.title or _('Untitled chapter')
            if not chapter.downloadable then label=label..'  ·  '.._('Unavailable') end
            items[#items+1]={text=label,select_enabled=chapter.downloadable,callback=function()
                if not current() or ctx.menu==nil or not chapter.downloadable then return end
                local menu=ctx.menu;ctx.menu=nil;UIManager:close(menu)
                ctx.chapter=chapter;ctx.phase='chapter'
                host:showBusy(_('Preparing E-Ink chapter...'),function() M.cancel(host) end);ctx.busy=host.busy_message
                launch()
            end}
        end
        local menu=host:showList(_('E-Ink chapters'),items,_('No chapters.'),
            {subtitle=_('Online: sync position or save selected highlights and private thoughts.')})
        if not menu then M.cancel(host);return end
        ctx.menu=menu
        local closed=menu.onCloseWidget
        menu.onCloseWidget=function(widget,...)
            if ctx.menu==widget and host._native_direct_reading==ctx then ctx.menu=nil;M.cancel(host) end
            if closed then return closed(widget,...) end
        end
        menu.close_callback=function()
            if ctx.menu==menu and host._native_direct_reading==ctx then ctx.menu=nil;M.cancel(host) end
        end
    end
    local function show_offline_catalog(rows)
        close_busy()
        local items,counts,ordinals={},{},{}
        for _index,entry in ipairs(rows) do counts[entry.chapter_uid]=(counts[entry.chapter_uid] or 0)+1 end
        for _index,row in ipairs(rows) do
            local entry=row
            local label=entry.title~='' and entry.title or _('Untitled chapter')
            label=label..'  ·  v'..tostring(entry.book_version)
            if counts[entry.chapter_uid]>1 then
                ordinals[entry.chapter_uid]=(ordinals[entry.chapter_uid] or 0)+1
                label=label..'  ·  '..T(_('Copy %1'),tostring(ordinals[entry.chapter_uid]))
            end
            items[#items+1]={text=label,callback=function()
                if not current() or not ctx.menu then return end
                local menu=ctx.menu;ctx.menu=nil;UIManager:close(menu)
                ctx.entry=entry;ctx.phase='offline_open'
                host:showBusy(_('Checking saved E-Ink chapter...'),function() M.cancel(host) end);ctx.busy=host.busy_message
                launch()
            end}
        end
        if #items==0 then fail('No usable saved E-Ink chapters for this book and account. Existing files are kept.');return end
        local menu=host:showList(_('Saved E-Ink chapters'),items,nil,
            {subtitle=_('Online: sync position or save selected highlights and private thoughts.')})
        if not menu then M.cancel(host);return end
        ctx.menu=menu
        local closed=menu.onCloseWidget
        menu.onCloseWidget=function(widget,...)
            if ctx.menu==widget and host._native_direct_reading==ctx then ctx.menu=nil;M.cancel(host) end
            if closed then return closed(widget,...) end
        end
        menu.close_callback=function()
            if ctx.menu==menu and host._native_direct_reading==ctx then ctx.menu=nil;M.cancel(host) end
        end
    end
    ctx.phase=offline and 'offline_list' or 'catalog'
    launch=function()
        if not current() then M.cancel(host);return end
        ctx.generation=(ctx.generation or 0)+1
        local generation,phase=ctx.generation,ctx.phase
        local ok,started=pcall(host._native_direct_worker.start,host._native_direct_worker,function()
            if phase=='offline_list' then
                local rows=require('weread.lib.native_direct_cache').list(host.settings,scope.vid,id,current)
                return rows and {rows=rows} or {error='storage'}
            elseif phase=='offline_open' then
                local result=require('weread.lib.native_direct_cache').open(host.settings,scope.vid,id,ctx.entry,current)
                return result or {error='damaged'}
            end
            if phase=='catalog' then
                local auth=require('weread.lib.native_authorization'):new(host.client,{
                    expected_vid=ctx.selected.native.scope.vid,is_current=current})
                local good,value=pcall(require('weread.lib.native_book_catalog').read,auth,
                    ctx.selected.native.credentials,id,'native_catalog')
                auth:cancel()
                if not good then
                    return {error=(value=='native_auth/native_catalog_info/http_401' or value=='native_auth/native_catalog_catalog/http_401') and 'auth_expired'
                        or (value=='native_auth/native_catalog_info/http_429' or value=='native_auth/native_catalog_catalog/http_429') and 'rate_limited' or 'unavailable'}
                end
                local result=project(value,id)
                return result or {error='unavailable'}
            end
            local expected={book_id=id,chapter_uid=ctx.chapter.chapterUid,book_version=ctx.catalog.version,
                reading_catalog_sha256=ctx.catalog.reading_digest,access_fingerprint=ctx.selected.native.fingerprint}
            local result,why=require('weread.lib.native_direct_reader').build(host.client,host.settings,
                ctx.book,ctx.chapter,expected,{is_current=current,allow_missing_images=true})
            return result or {error=why or 'unavailable'}
        end,function(result)
            if host._native_direct_reading~=ctx or ctx.generation~=generation then return end
            if not current() then M.cancel(host);return end
            if type(result)=='table' and result.error=='auth_expired' then renew();return end
            if type(result)=='table' and result.error=='rate_limited' then
                fail('WeRead is limiting requests. Please try again later.');return
            end
            if phase=='offline_list' then
                local rows=type(result)=='table' and result.rows
                local cache=require('weread.lib.native_direct_cache')
                if type(rows)~='table' or #rows>cache.MAX_ENTRIES then fail();return end
                local count,seen=0,{}
                for key in pairs(rows) do
                    if type(key)~='number' or key%1~=0 or key<1 or key>#rows then fail();return end
                    count=count+1
                end
                for _,entry in ipairs(rows) do
                    if not cache.valid_entry(entry,id,scope.vid) then fail();return end
                    local identity=entry.key..':'..tostring(entry.copy)
                    if seen[identity] then fail();return end
                    seen[identity]=true
                end
                if count~=#rows then fail();return end
                show_offline_catalog(rows);return
            end
            if phase=='catalog' then
                local checked=type(result)=='table' and project({book_id=result.book_id,version=result.version,
                    reading_digest=result.reading_digest,reading_chapters=result.chapters},id)
                if not checked then fail();return end
                ctx.catalog=checked
                if ctx.target then
                    local wanted=ctx.target;local chapter=checked.chapters[wanted.order]
                    local neighbor=chapter and (wanted.direction==1 and chapter.catalog_prev or chapter.catalog_next)
                    if checked.version~=wanted.book_version or checked.reading_digest~=wanted.catalog_sha256
                        or #checked.chapters~=wanted.count or not chapter or chapter.chapterUid~=wanted.uid
                        or neighbor~=wanted.from_uid then
                        fail('The chapter list changed. Please open it again.');return
                    end
                    if not chapter.downloadable then fail('The adjacent E-Ink chapter is unavailable.');return end
                    ctx.chapter=chapter;ctx.phase='chapter';launch();return
                end
                show_catalog(checked);return
            end
            local version=phase=='offline_open' and ctx.entry.book_version or ctx.catalog.version
            if type(result)~='table' or not require('weread.lib.native_direct_path').contains(host.settings,result.path)
                or not hash(result.source_sha256) or result.book_version~=version
                or not Protocol.integer(result.missing_images,0,64) then
                fail(phase=='offline_open' and 'The saved E-Ink chapter is damaged or has changed. The file was kept.'
                    or result and result.error=='catalog_changed' and 'The chapter list changed. Please open it again.' or nil);return
            end
            local path=result.path
            M.cancel(host)
            host:openFile(path)
        end)
        if not ok or not started then fail() end
    end
    host:showBusy(_(offline and 'Loading saved E-Ink chapters...' or 'Loading E-Ink chapters...'),function() M.cancel(host) end);ctx.busy=host.busy_message
    launch()
    return host._native_direct_reading==ctx
end
return M

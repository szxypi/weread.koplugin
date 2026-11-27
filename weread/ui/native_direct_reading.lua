-- Read E-Ink chapters through an isolated local-only reader, without using Web
-- position coordinates. Network and EPUB preparation run off the UI thread.
local UIManager=require('ui/uimanager')
local Access=require('weread.lib.native_read_access')
local Recovery=require('weread.lib.native_read_recovery')
local Protocol=require('weread.lib.native_position_protocol')
local ChapterSearch=require('weread.ui.chapter_search')
local Popup=require('weread.ui.shelf_popup')
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
            or row.wordCountKnown~=nil and type(row.wordCountKnown)~='boolean'
            or row.wordCountKnown==true and not Protocol.integer(row.wordCount,0,100000000)
            or row.wordCountKnown==false and row.wordCount~=nil and row.wordCount~=0
            or row.chapterIdx~=nil and not Protocol.integer(row.chapterIdx,0,1000000) then return nil end
        seen[row.chapterUid]=true
        rows[index]={chapterUid=row.chapterUid,title=row.title,chapterIdx=row.chapterIdx,downloadable=row.downloadable,
            wordCount=row.wordCountKnown and row.wordCount or nil,wordCountKnown=row.wordCountKnown,
            catalog_order=index,catalog_count=#model.reading_chapters}
    end
    for index,row in ipairs(rows) do
        row.catalog_prev=rows[index-1] and rows[index-1].chapterUid or nil
        row.catalog_next=rows[index+1] and rows[index+1].chapterUid or nil
    end
    return {book_id=id,version=model.version,reading_digest=model.reading_digest,chapters=rows}
end
M.project=project

local function current_row(rows,entry,catalog)
    if not entry or catalog and entry.book_version~=catalog.version then return nil end
    for index,row in ipairs(rows) do
        if catalog then
            if row.chapterUid==entry.chapter_uid then return index end
        elseif row.chapter_uid==entry.chapter_uid and row.book_version==entry.book_version
            and row.key==entry.key and row.copy==entry.copy and row.source_sha256==entry.source_sha256 then
            return index
        end
    end
end

function M.cancel(host)
    local ctx=host._native_direct_reading
    if not ctx then return end
    host._native_direct_reading=nil
    if host._native_direct_worker then host._native_direct_worker:cancel() end
    if host._native_direct_worker then host._native_direct_worker.timeout=180 end
    Recovery.cancel(host,ctx)
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
    ctx.busy=nil
    local menu=ctx.menu;ctx.menu=nil
    if menu then UIManager:close(menu) end
    local confirm=ctx.confirm;ctx.confirm=nil
    if confirm then UIManager:close(confirm) end
end

function M.start(host,book,view,options)
    if type(book)~='table' or not view or host._book_detail_view~=view then return false end
    local cleanup=package.loaded['weread.ui.native_direct_cleanup'];if cleanup then cleanup.cancel(host) end
    local id=Protocol.id(book.book_id or book.bookId)
    if not id then return false end
    local cached=type(options)=='table' and options.cached==true
    local online=not cached and (host.isNetworkConnected and host:isNetworkConnected()
        or not host.isNetworkConnected and host:isNetworkOnline())
    local offline=not online
    local batch=type(options)=='table' and options.batch==true
    if batch and offline then host:showOffline(_('Download E-Ink chapters'));return false end
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
    local failed_copy=type(options)=='table' and options.failed_copy or nil
    if failed_copy and (not cached or not require('weread.lib.native_direct_cache').valid_entry(failed_copy,id,scope.vid)) then return false end
    local anchor=type(options)=='table' and options.anchor or nil
    if anchor and not require('weread.lib.native_direct_cache').valid_entry(anchor,id,scope.vid) then anchor=nil end
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
        book={book_id=id,title=title,author=author},scope=scope,offline=offline,target=target,batch=batch}
    host._native_direct_reading=ctx
    local function view_current()
        local now=host.ui and host.ui.document
        return host._native_direct_reading==ctx and not host._weread_suspended and host._book_detail_view==view
            and (host.discovery_epoch or 0)==ctx.epoch and host._reader_session_gen==ctx.session
            and now==ctx.document and (not now or now.file==ctx.file)
            and (not host.library_db or host.library_db:accountKey()==ctx.account)
            and host.settings:auth_scope_matches(ctx.scope)
    end
    local current=offline and view_current or Access.guard(host.settings,view_current,selected.native)
    local function close_busy()
        if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
        ctx.busy=nil
    end
    local function finish_saved_check()
        ctx.generation=ctx.generation+1
        ctx.entry=nil
        host._native_direct_worker:cancel()
        close_busy()
    end
    local function fail(message)
        if host._native_direct_reading~=ctx then return end
        local live=view_current()
        if live and ctx.entry and ctx.menu then finish_saved_check() else M.cancel(host) end
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
                current=Access.guard(host.settings,view_current,fresh.native)
                launch()
            end})
        if not started then fail('E-Ink authorization expired. Please authorize again.') end
    end
    local function show_chapter_menu(rows,picker)
        if #rows==0 then fail('No usable saved E-Ink chapters for this book and account. Existing files are kept.');return end
        close_busy()
        local saved_labels=offline and require('weread.ui.native_direct_copies').labels(rows)
        local empty_title=_('Untitled chapter')
        local subtitle=picker and picker.subtitle
            or failed_copy and _('The last E-Ink chapter is unavailable. Choose another saved chapter.')
            or offline and _('Each copy keeps its own reading position. Reopen online to retry missing images.')
            or _('Online: sync position or save selected highlights and private thoughts.')
        local current_index=not picker and current_row(rows,anchor,ctx.catalog)
        local search=''
        local by_index,menu
        local function items()
            local matches,counts=ChapterSearch.filter(rows,search,empty_title)
            local result={}
            by_index={}
            for number=1,(matches and #matches or #rows) do
                local index=matches and matches[number] or number
                local row=rows[index]
                local chapter_title=row.title~='' and row.title or empty_title
                local label=picker and T('%1. %2',index,chapter_title)
                    or ChapterSearch.label(chapter_title,row.catalog_order,counts,saved_labels and saved_labels[index])
                if not offline and not row.downloadable then label=label..'  ·  '.._('Unavailable') end
                if row.pending_offline then label=label..'  ·  '.._('Offline position to review') end
                if index==current_index then label=_('Current chapter')..' · '..label end
                local item={text=label,select_enabled=picker~=nil or offline or row.downloadable,chapter_index=index}
                result[number],by_index[index]=item,item
            end
            if #result==0 then result[1]={text=_('No matching chapters.'),select_enabled=false} end
            return result
        end
        local menu_title=picker and picker.title or _(offline and 'Saved E-Ink chapters' or 'E-Ink chapters')
        menu=host:showList(menu_title,items(),nil,
            {subtitle=subtitle,left_icon='appbar.search',on_choice=function(item)
                local index=type(item)=='table' and item.chapter_index
                if ctx.menu~=menu or not index or by_index[index]~=item or not item.select_enabled then return end
                if not current() then M.cancel(host);return end
                if ctx.entry then return end
                local busy
                local function cancel_open()
                    if host._native_direct_reading~=ctx or ctx.busy~=busy then return end
                    if ctx.entry and ctx.menu==menu and current() then finish_saved_check()
                    else M.cancel(host) end
                end
                if offline and not picker then
                    Popup.close(menu)
                    ctx.entry=rows[index];ctx.phase='offline_open'
                else
                    ctx.menu=nil;UIManager:close(menu)
                    if picker then picker.choose(index);return end
                    ctx.chapter=rows[index];ctx.phase='chapter'
                end
                host:showBusy(_(offline and 'Checking saved E-Ink chapter...' or 'Preparing E-Ink chapter...'),
                    cancel_open)
                busy=host.busy_message;ctx.busy=busy
                launch()
            end})
        if not menu then M.cancel(host);return end
        ctx.menu=menu
        local closed=menu.onCloseWidget
        menu.onCloseWidget=function(widget,...)
            widget._shelf_closed=true
            Popup.close(widget)
            if ctx.menu==widget and host._native_direct_reading==ctx then ctx.menu=nil;M.cancel(host) end
            if closed then return closed(widget,...) end
        end
        menu.onLeftButtonTap=function()
            ChapterSearch.prompt(host,menu,search,function()
                return ctx.menu==menu and not ctx.entry and current()
            end,function(query)
                search=query
                menu.subtitle=search~='' and T(_('Chapter filter: %1'),search) or subtitle
                menu:switchItemTable(nil,items(),search=='' and current_index or nil,nil,menu.subtitle)
            end)
            return true
        end
        local initial_index=picker and picker.start or current_index
        if initial_index then menu:onGotoPage(menu:getPageNumber(initial_index)) end
    end
    local function start_batch(range)
        ctx.batch_range=range
        ctx.phase='batch';host._native_direct_worker.timeout=3600
        local ok,widget=pcall(function() return require('weread.ui.download_dialog'):new{
            title=_('Download E-Ink chapters'),
            description=_('Readable chapters are saved individually. Cancel to keep completed chapters.'),
            buttons={{{text=_('Cancel'),callback=function() M.cancel(host) end}}},
        } end)
        if not ok or not widget then fail();return end
        host.busy_message=widget;ctx.busy=widget;widget:show();launch()
    end
    local function take_confirmation(dialog)
        if ctx.confirm~=dialog then return false end
        ctx.confirm=nil
        if current() then return true end
        M.cancel(host);return false
    end
    local function show_confirmation(dialog)
        ctx.confirm=dialog
        local closed=dialog.onCloseWidget
        dialog.onCloseWidget=function(widget,...)
            if ctx.confirm==widget then ctx.confirm=nil;M.cancel(host) end
            if closed then return closed(widget,...) end
        end
        UIManager:show(dialog)
    end
    local function show_batch_options(chapters)
        local function count_readable(first,last)
            local count=0
            for index=first,last do if chapters[index].downloadable then count=count+1 end end
            return count
        end
        local available=count_readable(1,#chapters)
        if available==0 then fail('No readable E-Ink chapters are available for this book.');return end
        local function choose_end(start)
            show_chapter_menu(chapters,{title=_('Choose the last chapter to download'),start=start,
                subtitle=T(_('Chapter %1 selected first'),start),choose=function(ending)
                    local first,last=math.min(start,ending),math.max(start,ending)
                    local count=count_readable(first,last)
                    if count==0 then
                        choose_end(start);host:showInfo(_('No readable E-Ink chapters in this range.'));return
                    end
                    local confirm
                    confirm=require('ui/widget/confirmbox'):new{
                        text=T(_('Save chapters %1–%2 for offline reading? %3 readable chapters will be saved. %4 unavailable chapters will be skipped.'),
                            first,last,count,last-first+1-count),
                        ok_text=_('Download'),cancel_text=_('Cancel'),
                        ok_callback=function() if take_confirmation(confirm) then start_batch({first=first,last=last}) end end,
                        cancel_callback=function() if take_confirmation(confirm) then M.cancel(host) end end,
                    }
                    show_confirmation(confirm)
                end})
        end
        local dialog
        dialog=require('ui/widget/multiconfirmbox'):new{
            text=T(_('Choose how to save %1 readable E-Ink chapters. %2 unavailable chapters will be skipped.'),
                available,#chapters-available),
            choice1_text=_('Select range'),choice2_text=_('Download all'),cancel_text=_('Cancel'),
            choice1_callback=function()
                if take_confirmation(dialog) then
                    show_chapter_menu(chapters,{title=_('Choose the first chapter to download'),
                        subtitle=_('Unavailable chapters in the range will be skipped.'),choose=choose_end})
                end
            end,
            choice2_callback=function() if take_confirmation(dialog) then start_batch() end end,
            cancel_callback=function() if take_confirmation(dialog) then M.cancel(host) end end,
        }
        show_confirmation(dialog)
    end
    ctx.phase=offline and 'offline_list' or 'catalog'
    launch=function()
        if not current() then M.cancel(host);return end
        ctx.generation=(ctx.generation or 0)+1
        local generation,phase,saved_entry=ctx.generation,ctx.phase,ctx.entry
        local ok,started=pcall(host._native_direct_worker.start,host._native_direct_worker,function(progress)
            if phase=='batch' then
                return require('weread.lib.native_direct_batch').run(host.client,host.settings,ctx.book,ctx.catalog,
                    ctx.selected.native,current,progress,ctx.batch_range)
            end
            if phase=='offline_list' then
                local rows=require('weread.lib.native_direct_cache').list(host.settings,scope.vid,id,current)
                if rows and host.library_db then
                    pcall(require('weread.lib.native_direct_pending').mark,host.library_db,host.settings,scope,id,rows,current)
                end
                return rows and {rows=rows} or {error='storage'}
            elseif phase=='offline_open' then
                local result=require('weread.lib.native_direct_cache').open(host.settings,scope.vid,id,saved_entry,current)
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
                if result and host.library_db then
                    pcall(require('weread.lib.native_direct_catalog_store').save,host.library_db,host.settings,host.client,
                        scope,result,current)
                end
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
                if phase=='batch' then
                    M.cancel(host);host:showInfo(_('WeRead is limiting requests. Completed chapters were kept; try again later.'));return
                end
                fail('WeRead is limiting requests. Please try again later.');return
            end
            if phase=='batch' then
                local range=ctx.batch_range
                local count=range and range.last-range.first+1 or #ctx.catalog.chapters
                local good=type(result)=='table' and result.ok==true
                    and Protocol.integer(result.downloaded,0,count)
                    and Protocol.integer(result.saved,0,count)
                    and Protocol.integer(result.unavailable,0,count)
                    and Protocol.integer(result.missing,0,count)
                    and result.downloaded+result.saved+result.unavailable==count
                    and result.missing<=result.downloaded+result.saved
                local downloaded,saved,unavailable,missing=good and result.downloaded,good and result.saved,
                    good and result.unavailable,good and result.missing
                M.cancel(host)
                if good then
                    host:showInfo(T(_('E-Ink chapters ready: %1 downloaded, %2 already saved, %3 unavailable. %4 chapters have missing images.'),
                        tostring(downloaded),tostring(saved),tostring(unavailable),tostring(missing)))
                else host:showInfo(_('The download stopped. Completed E-Ink chapters were kept; check the connection or storage and try again.')) end
                return
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
                    if not cache.valid_entry(entry,id,scope.vid)
                        or entry.pending_offline~=nil and entry.pending_offline~=true then fail();return end
                    local identity=entry.key..':'..tostring(entry.copy)
                    if seen[identity] then fail();return end
                    seen[identity]=true
                end
                if count~=#rows then fail();return end
                if failed_copy then
                    for index,row in ipairs(rows) do
                        if row.key==failed_copy.key and row.copy==failed_copy.copy then table.remove(rows,index);break end
                    end
                end
                show_chapter_menu(rows);return
            end
            if phase=='catalog' then
                local checked=type(result)=='table' and project({book_id=result.book_id,version=result.version,
                    reading_digest=result.reading_digest,reading_chapters=result.chapters},id)
                if not checked then fail();return end
                ctx.catalog=checked
                if ctx.batch then
                    close_busy()
                    show_batch_options(checked.chapters);return
                end
                if ctx.target then
                    local wanted=ctx.target;local chapter=checked.chapters[wanted.order]
                    local neighbor=chapter and chapter[wanted.direction==1 and 'catalog_prev' or 'catalog_next']
                    if checked.version~=wanted.book_version or checked.reading_digest~=wanted.catalog_sha256
                        or #checked.chapters~=wanted.count or not chapter or chapter.chapterUid~=wanted.uid
                        or neighbor~=wanted.from_uid then
                        fail('The chapter list changed. Please open it again.');return
                    end
                    if not chapter.downloadable then fail('The adjacent E-Ink chapter is unavailable.');return end
                    ctx.chapter=chapter;ctx.phase='chapter';launch();return
                end
                show_chapter_menu(checked.chapters);return
            end
            local version=phase=='offline_open' and saved_entry.book_version or ctx.catalog.version
            if type(result)~='table' or not require('weread.lib.native_direct_path').contains(host.settings,result.path)
                or not hash(result.source_sha256) or result.book_version~=version
                or not Protocol.integer(result.missing_images,0,64) then
                local reason=type(result)=='table' and result.error
                fail(reason=='damaged' and 'The saved E-Ink chapter is damaged or has changed. The file was kept.'
                    or reason=='catalog_changed' and 'The chapter list changed. Please open it again.' or nil);return
            end
            local path=result.path
            M.cancel(host)
            host:openFile(path)
        end,phase=='batch' and function(value)
            if host._native_direct_reading~=ctx then return end
            if not current() or ctx.busy~=host.busy_message then M.cancel(host);return end
            if type(value)=='number' and value>=0 and value<=99 and value%1==0
                and value>(ctx.batch_progress or -1) then
                ctx.batch_progress=value
                ctx.busy:reportProgress(value)
            end
        end or nil)
        if not ok or not started then fail() end
    end
    host:showBusy(_(offline and 'Loading saved E-Ink chapters...' or 'Loading E-Ink chapters...'),function() M.cancel(host) end);ctx.busy=host.busy_message
    launch()
    return host._native_direct_reading==ctx
end
return M

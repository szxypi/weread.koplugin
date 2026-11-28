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
local catalog_errors={http_401='auth_expired',http_429='rate_limited',transport='transport',timeout='transport',
    http_500='server_unavailable',http_502='server_unavailable',http_503='server_unavailable',http_504='server_unavailable'}

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
            or row.level~=nil and not Protocol.integer(row.level,0,100)
            or row.chapterIdx~=nil and not Protocol.integer(row.chapterIdx,0,1000000) then return nil end
        seen[row.chapterUid]=true
        rows[index]={chapterUid=row.chapterUid,title=row.title,chapterIdx=row.chapterIdx,downloadable=row.downloadable,
            wordCount=row.wordCountKnown and row.wordCount or nil,wordCountKnown=row.wordCountKnown,level=row.level,
            catalog_order=index,catalog_count=#model.reading_chapters}
    end
    for index,row in ipairs(rows) do
        row.catalog_prev=rows[index-1] and rows[index-1].chapterUid or nil
        row.catalog_next=rows[index+1] and rows[index+1].chapterUid or nil
    end
    return {book_id=id,version=model.version,reading_digest=model.reading_digest,chapters=rows}
end
M.project=project

-- A section starts where the next chapter is deeper. Count actual ancestors
-- so a catalog that skips level numbers does not over-indent its titles.
local function chapter_outline(rows,visible)
    local sections,depths,headings,parents={},{},{},{}
    for index,row in ipairs(rows) do
        local level=row.level or 1
        while #parents>0 and parents[#parents].level>=level do parents[#parents]=nil end
        if #parents>0 then depths[index]=math.min(#parents,3) end
        local target=not visible and index or visible[index]
        if target then
            for i=#parents,1,-1 do
                if parents[i].target then break end
                parents[i].target=target
            end
        end
        local following=rows[index+1]
        if following and (following.level or 1)>level then
            local section={order=index,title=row.title,level=level,depth=depths[index],target=target}
            sections[#sections+1]=section
            headings[index]=true
            parents[#parents+1]=section
        end
    end
    local available={}
    for _,section in ipairs(sections) do
        if section.target then available[#available+1]=section end
    end
    if #available>0 then return available,depths,headings end
end

local function saved_catalog_entry(rows,anchor)
    if anchor and anchor.catalog_sha256 then return anchor end
    local entry
    for _,row in ipairs(rows) do
        if row.catalog_sha256 then
            if entry and (entry.catalog_sha256~=row.catalog_sha256 or entry.book_version~=row.book_version) then return nil end
            entry=row
        end
    end
    return entry
end

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

local function cloud_row(rows,hint)
    if type(hint)~='table' or not Protocol.id(hint.uid) then return nil end
    for index,row in ipairs(rows) do
        if row.chapterUid==hint.uid and (row.chapterIdx==nil or hint.idx==nil or row.chapterIdx==hint.idx) then return index end
    end
end

local function direct_chapter(catalog,cloud)
    if type(cloud)~='table' then return end
    if cloud.unstarted==true then return catalog.chapters[1] end
    local index=cloud_row(catalog.chapters,cloud)
    local chapter=index and catalog.chapters[index]
    local position=chapter and cloud.target
    if position and require('weread.lib.native_direct_resume').valid_target(position)
        and position.book_id==catalog.book_id and position.chapter_uid==chapter.chapterUid
        and position.chapter_idx==cloud.idx then return chapter,position end
end

local function connected(host)
    return host.isNetworkConnected and host:isNetworkConnected()
        or not host.isNetworkConnected and host:isNetworkOnline()
end

local function matches_catalog(entry,chapter,catalog)
    return entry.chapter_uid==chapter.chapterUid and entry.book_version==catalog.version
        and entry.catalog_sha256==catalog.reading_digest and entry.catalog_order==chapter.catalog_order
        and entry.catalog_count==chapter.catalog_count and entry.catalog_prev==chapter.catalog_prev
        and entry.catalog_next==chapter.catalog_next
end

local function valid_saved_rows(rows,id,vid)
    local cache=require('weread.lib.native_direct_cache')
    if type(rows)~='table' or #rows>cache.MAX_ENTRIES then return false end
    local count,seen=0,{}
    for index in pairs(rows) do
        if not Protocol.integer(index,1,#rows) then return false end
        count=count+1
    end
    if count~=#rows then return false end
    for _,entry in ipairs(rows) do
        if not cache.valid_entry(entry,id,vid) or entry.pending_offline~=nil and entry.pending_offline~=true then
            return false
        end
        local identity=entry.key..':'..tostring(entry.copy)
        if seen[identity] then return false end
        seen[identity]=true
    end
    return true
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
    local copies=ctx.copy_menu;ctx.copy_menu=nil
    if copies then UIManager:close(copies) end
    local menu=ctx.menu;ctx.menu=nil
    if menu then UIManager:close(menu) end
    local confirm=ctx.confirm;ctx.confirm=nil
    if confirm then UIManager:close(confirm) end
    if ctx.pending_shelf_redraw then Popup.resumeMetadata(host,ctx) end
end

function M.start(host,book,view,options)
    local from_reader=type(options)=='table' and options.from_reader==true
    local shelf_current=type(options)=='table' and options.shelf_current
    local from_shelf=type(shelf_current)=='function'
    local owner_key=from_reader and 'ui' or from_shelf and 'shelf_view' or '_book_detail_view'
    if type(book)~='table' or not view or host[owner_key]~=view then return false end
    if from_shelf and (from_reader or not shelf_current()) then return false end
    local document=host.ui and host.ui.document
    if from_reader and not require('weread.lib.native_direct_path').contains(host.settings,document and document.file) then
        return false
    end
    local cleanup=package.loaded['weread.ui.native_direct_cleanup'];if cleanup then cleanup.cancel(host) end
    local id=Protocol.id(book.book_id or book.bookId)
    if not id then return false end
    local cached=type(options)=='table' and options.cached==true
    local offline_notice=cached and from_reader and options.offline_notice
    local offline=cached or not connected(host)
    local repair_images=type(options)=='table' and options.repair_images==true
    local batch=repair_images or type(options)=='table' and options.batch==true
    local resume_plan=type(options)=='table' and options.resume_plan or nil
    local batch_title=_(repair_images and 'Recover missing images in downloaded chapters' or 'Download E-Ink chapters')
    if batch and offline then host:showOffline(batch_title);return false end
    local scope=host.settings:get_auth_scope()
    if not scope or not host.settings:auth_scope_matches(scope) then
        host:showInfo(_('Sign in to the account that saved these E-Ink chapters.'))
        return false
    end
    local Cache=require('weread.lib.native_direct_cache')
    local anchor=type(options)=='table' and options.anchor or nil
    if anchor and not Cache.valid_entry(anchor,id,scope.vid) then anchor=nil end
    local target=type(options)=='table' and options.target or nil
    if target and (not from_reader or cached or batch or type(target)~='table' or not anchor or not anchor.catalog_sha256
        or target.direction~=1 and target.direction~=-1
        or target.from_uid~=anchor.chapter_uid or target.catalog_sha256~=anchor.catalog_sha256
        or target.book_version~=anchor.book_version or target.count~=anchor.catalog_count
        or target.order~=anchor.catalog_order+target.direction
        or not target.uid or target.uid~=anchor[target.direction==1 and 'catalog_next' or 'catalog_prev']) then return false end
    local failed_copy=type(options)=='table' and options.failed_copy or nil
    if failed_copy and (not (cached or target) or not Cache.valid_entry(failed_copy,id,scope.vid)
        or target and (failed_copy.chapter_uid~=target.uid or failed_copy.catalog_sha256~=target.catalog_sha256
            or failed_copy.book_version~=target.book_version)) then return false end
    local resume_fallback=cached and not from_reader and (failed_copy or options.resume_fallback==true)
    local adjacent_direction=type(options)=='table' and options.adjacent_direction
    if adjacent_direction and (not from_reader or batch or target or not anchor or anchor.catalog_sha256
        or adjacent_direction~=-1 and adjacent_direction~=1) then return false end
    if target and offline then
        offline_notice='Chapter unavailable offline'
        target=nil
    end
    local want_cloud_chapter=not anchor and not batch and not target and type(options)=='table' and options.cloud_chapter==true
    local standard_read=want_cloud_chapter and not from_reader and type(options.standard_read)=='function' and options.standard_read
    local selected=not offline and capture(host.settings) or nil
    local fallback_reason,offer_standard,catalog_notice
    if not offline and (not selected or selected.native.renewal_pending) then
        fallback_reason='E-Ink authorization is required to read these chapters.'
        if batch then host:showInfo(_(fallback_reason));return false end
        offline,selected,target=true,nil,nil
        offer_standard=true
    end
    local title=text(book.title,2048) and book.title or id
    local author=text(book.author,2048) and book.author or ''
    local ctx={epoch=host.discovery_epoch or 0,session=host._reader_session_gen,document=document,
        file=document and document.file,account=host.library_db and host.library_db:accountKey(),selected=selected,
        book={book_id=id,title=title,author=author},scope=scope,offline=offline,target=target,batch=batch,
        shelf_owner=from_shelf and view or nil}
    if batch and not repair_images and host.library_db then
        ctx.batch_store=require('weread.lib.native_direct_batch_plan'):new(host.library_db,scope)
    end
    if resume_plan and (not ctx.batch_store or not ctx.batch_store:verified(resume_plan,id)) then return false end
    M.cancel(host)
    host._native_direct_reading=ctx
    local function origin_current()
        local now=host.ui and host.ui.document
        return not host._weread_suspended and host[owner_key]==view
            and (not from_shelf or shelf_current())
            and (host.discovery_epoch or 0)==ctx.epoch and host._reader_session_gen==ctx.session
            and now==ctx.document and (not now or now.file==ctx.file)
            and (not host.library_db or host.library_db:accountKey()==ctx.account)
            and host.settings:auth_scope_matches(ctx.scope)
    end
    local function view_current()
        return host._native_direct_reading==ctx and origin_current()
    end
    local current=offline and view_current or Access.guard(host.settings,view_current,selected.native)
    local function phase_guard(phase)
        return (phase=='offline_open' or phase=='saved_matches') and view_current or current
    end
    local function close_busy()
        if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
        ctx.busy=nil
    end
    local function stop_chapter_open()
        ctx.generation=ctx.generation+1
        ctx.entry=nil
        ctx.chapter=nil
        ctx.cloud_target=nil
        ctx.recovery_attempted=nil
        host._native_direct_worker:cancel()
        close_busy()
    end
    local show_chapter_menu
    local function show_resume_catalog(after_close)
        local cloud=ctx.auto_open;ctx.auto_open=nil
        local copies=ctx.copy_menu;ctx.copy_menu=nil
        if copies then UIManager:close(copies) end
        stop_chapter_open()
        local function show()
            if host._native_direct_reading~=ctx then return end
            if current() then show_chapter_menu(ctx.catalog.chapters,nil,nil,cloud) else M.cancel(host) end
        end
        if after_close then UIManager:nextTick(show) else show() end
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
    local function can_read_standard()
        return standard_read and view_current() and connected(host)
            and require('weread.lib.shelf_source').web_access(host.settings)~=nil
    end
    local function confirm_alternative(notice,question,label,available,open)
        ctx.generation=(ctx.generation or 0)+1
        close_busy()
        local dialog
        dialog=require('ui/widget/confirmbox'):new{
            text=notice..'\n\n'..question,
            ok_text=label,cancel_text=_('Cancel'),keep_dialog_open=true,
            ok_callback=function()
                if ctx.confirm~=dialog then return end
                local choice=available()
                M.cancel(host)
                if choice and origin_current() then open(choice) end
            end,
            cancel_callback=function()
                if ctx.confirm==dialog then ctx.confirm=nil;M.cancel(host) end
            end,
        }
        show_confirmation(dialog)
    end
    local function cached_standard_copy()
        if not resume_fallback or not view_current() then return end
        local record=require('weread.lib.read_access').load_cached_book(host.settings,id)
        if record and (not record._library_account_key or record._library_account_key==ctx.account)
            and host:bookRecordHasDownload(record) then return record end
    end
    local function open_cached_standard(record)
        return host:readCachedCopy(record,not from_shelf and view or nil)
    end
    local function fail(message,close_catalog,try_standard)
        if host._native_direct_reading~=ctx then return end
        local notice=_(message or 'Could not prepare the E-Ink chapter. Please try again.')
        if try_standard and can_read_standard() then
            confirm_alternative(notice,_('Continue with standard reading?'),_('Use standard reading'),
                can_read_standard,standard_read)
            return
        end
        local live=view_current()
        if live and not close_catalog and ctx.busy and phase_guard(ctx.phase)() then
            if ctx.auto_open then show_resume_catalog()
            elseif ctx.menu then stop_chapter_open()
            else M.cancel(host) end
        else M.cancel(host) end
        if live then host:showInfo(notice) end
    end
    if not host._native_direct_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
            scheduler=UIManager,codec=host.client,max_bytes=8*1024*1024,timeout=180} end)
        if not ok then fail();return false end
        host._native_direct_worker=worker
    end
    local launch
    local function load_chapters(phase)
        close_busy()
        ctx.phase=phase
        local busy
        host:showBusy(_(phase=='offline_list' and 'Loading saved E-Ink chapters...' or 'Loading E-Ink chapters...'),function()
            if host._native_direct_reading==ctx and ctx.busy==busy then M.cancel(host) end
        end)
        busy=host.busy_message;ctx.busy=busy
        launch()
    end
    local function load_saved_chapters(message,try_standard,notice)
        fallback_reason=message or 'Could not prepare the E-Ink chapter. Please try again.'
        offer_standard=try_standard
        offline_notice=notice or offline_notice
        offline,ctx.offline,ctx.selected=true,true,nil
        ctx.target,ctx.chapter,ctx.catalog=nil,nil,nil
        current=view_current
        load_chapters('offline_list')
    end
    local function catalog_unavailable(message,try_standard)
        if ctx.batch or not view_current() or not ctx.target and (ctx.phase~='catalog' or ctx.catalog) then
            fail(message,true,try_standard);return
        end
        load_saved_chapters(message,try_standard)
    end
    local function begin_open(phase)
        ctx.phase=phase
        local busy
        host:showBusy(_(phase=='chapter' and 'Preparing E-Ink chapter...' or 'Checking saved E-Ink chapter...'),function()
            if host._native_direct_reading~=ctx or ctx.busy~=busy then return end
            if ctx.menu and not ctx.renewing and phase_guard(phase)() then stop_chapter_open()
            else M.cancel(host) end
        end)
        busy=host.busy_message;ctx.busy=busy
        launch()
    end
    local function show_saved_copies(rows,complete_only)
        close_busy()
        local labels=require('weread.ui.native_direct_copies').labels(rows)
        local items,menu={}
        for index,label in ipairs(labels) do items[index]={text=label,copy_index=index} end
        menu=host:showList(_('Choose a saved chapter copy'),items,nil,{
            subtitle=_(complete_only and 'Each copy keeps its own reading position.'
                or 'Each copy keeps its own reading position. Reopen online to retry missing images.'),
            on_choice=function(item)
                local index=type(item)=='table' and item.copy_index
                if not menu or ctx.copy_menu~=menu or ctx.busy or not index or items[index]~=item then return end
                if not view_current() then M.cancel(host);return end
                ctx.entry=rows[index]
                begin_open('offline_open')
            end,
        })
        if not menu then fail();return end
        ctx.copy_menu=menu
        local closed=menu.onCloseWidget
        menu.onCloseWidget=function(widget,...)
            if ctx.copy_menu==widget then
                ctx.copy_menu=nil
                if ctx.auto_open then show_resume_catalog(true)
                elseif ctx.busy then stop_chapter_open() end
            end
            if closed then return closed(widget,...) end
        end
    end
    local function renew()
        local started=Recovery.start(host,ctx,ctx.selected,{capture=capture,is_current=view_current,
            stale=function() if host._native_direct_reading==ctx then M.cancel(host) end end,
            complete=function(ok,fresh)
                ctx.selected=fresh
                if not ok then catalog_unavailable('E-Ink authorization expired. Please authorize again.',true);return end
                current=Access.guard(host.settings,view_current,fresh.native)
                launch()
            end})
        if not started then catalog_unavailable('E-Ink authorization expired. Please authorize again.',true) end
    end
    show_chapter_menu=function(rows,picker,saved_catalog,cloud_chapter)
        if #rows==0 then
            if cached_standard_copy() then
                confirm_alternative(_('The last E-Ink chapter is unavailable.'),
                    _('Open the standard downloaded copy at its saved reading position?'),_('Read cached copy'),
                    cached_standard_copy,open_cached_standard)
                return
            end
            fail(offline_notice or fallback_reason or 'No usable saved E-Ink chapters for this book and account. Existing files are kept.',
                nil,offer_standard);return
        end
        close_busy()
        local orders,sections,depths,headings
        if saved_catalog then
            orders=require('weread.lib.native_direct_catalog_store').saved_orders(saved_catalog,rows)
            if orders then
                local positions={}
                for index=1,#rows do positions[index]=index end
                table.sort(positions,function(a,b)
                    local left,right=orders[a] or math.huge,orders[b] or math.huge
                    if left~=right then return left<right end
                    return a<b
                end)
                local sorted,sorted_orders,visible={},{},{}
                for index,old_index in ipairs(positions) do
                    local order=orders[old_index]
                    sorted[index],sorted_orders[index]=rows[old_index],order
                    if order and not visible[order] then visible[order]=index end
                end
                rows,orders=sorted,sorted_orders
                sections,depths,headings=chapter_outline(saved_catalog.chapters,visible)
            end
        elseif not offline then sections,depths,headings=chapter_outline(rows) end
        local saved_labels=offline and require('weread.ui.native_direct_copies').labels(rows)
        local empty_title=_('Untitled chapter')
        local filter_titles=ChapterSearch.title_filter(rows,empty_title,offline)
        local current_index
        if picker then
            local row=anchor and rows[anchor.catalog_order]
            if row and matches_catalog(anchor,row,ctx.catalog) then current_index=anchor.catalog_order end
        else
            current_index=current_row(rows,anchor,ctx.catalog)
        end
        local adjacent_index,adjacent_notice
        if adjacent_direction and not offline then
            local current_chapter=current_index and rows[current_index]
            if ctx.catalog.version==0 or current_chapter and anchor.chapter_idx~=nil
                and current_chapter.chapterIdx~=anchor.chapter_idx then current_index=nil end
            if current_index then
                local index=current_index+adjacent_direction
                if rows[index] then adjacent_index=index
                else adjacent_notice=_(adjacent_direction==1 and 'You have reached the last chapter.'
                    or 'You have reached the first chapter.') end
            end
            adjacent_notice=adjacent_notice or _('Choose a chapter from the updated list.')
        end
        local subtitle=picker and picker.subtitle
            or offline_notice and _(offline_notice)
            or (failed_copy or resume_fallback) and _('The last E-Ink chapter is unavailable. Choose another saved chapter.')
            or fallback_reason and _('The online catalog is unavailable. Showing saved chapters.')
            or offline and _('Each copy keeps its own reading position. Reopen online to retry missing images.')
            or catalog_notice or adjacent_notice or _('Online: sync position or save selected highlights and private thoughts.')
        local cloud_index=not current_index and cloud_row(rows,cloud_chapter) or nil
        local initial_index=picker and picker.start or adjacent_index or current_index or cloud_index
        local screen=require('device').screen
        local indent=sections and screen:scaleBySize(16)
        -- A single item per page can otherwise make the keyboard shortcut
        -- as wide as the screen, leaving no room for chapter titles.
        local shortcut_width=screen:scaleBySize(24)
        local search=''
        local by_index,menu,unfiltered_position
        local function items()
            local matches,counts=filter_titles(search)
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
                if index==current_index then label=_('Current chapter')..' · '..label
                elseif index==adjacent_index then label=_(adjacent_direction==1 and 'Next chapter' or 'Previous chapter')..' · '..label
                elseif index==cloud_index then label=_('Cloud reading chapter')..' · '..label end
                local order=not offline and index or orders and orders[index]
                local item={text=label,select_enabled=picker~=nil or offline or row.downloadable,chapter_index=index,
                    bold=order and headings and headings[order],indent=order and depths and depths[order] and depths[order]*indent,
                    shortcut_icon_width=shortcut_width}
                result[number],by_index[index]=item,item
            end
            if #result==0 then
                result[1]={text=_('No matching chapters.'),select_enabled=false,shortcut_icon_width=shortcut_width}
            end
            return result
        end
        local menu_title=picker and picker.title or _(offline and 'Saved E-Ink chapters' or 'E-Ink chapters')
        local standard_available=cached_standard_copy()~=nil
        local show_actions=sections or standard_available
        menu=host:showList(menu_title,items(),nil,
            {subtitle=subtitle,left_icon=show_actions and 'appbar.menu' or 'appbar.search',on_choice=function(item)
                local index=type(item)=='table' and item.chapter_index
                if ctx.menu~=menu or ctx.busy or ctx.copy_menu or not index
                    or by_index[index]~=item or not item.select_enabled then return end
                if not view_current() then M.cancel(host);return end
                if picker then
                    if not current() then M.cancel(host);return end
                    ctx.menu=nil;UIManager:close(menu)
                    picker.choose(index);return
                end
                Popup.close(menu)
                if offline then
                    ctx.entry=rows[index]
                    begin_open('offline_open')
                else
                    ctx.chapter=rows[index]
                    ctx.cloud_target=index==cloud_index and cloud_chapter.target or nil
                    begin_open(connected(host) and 'chapter' or 'saved_matches')
                end
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
        local function menu_current()
            return ctx.menu==menu and not ctx.busy and not ctx.copy_menu and view_current()
        end
        local function filter(query,index,focus)
            search=query
            menu.subtitle=search~='' and T(_('Chapter filter: %1'),search) or subtitle
            menu.itemnumber=focus
            menu:switchItemTable(nil,items(),focus or index,nil,menu.subtitle)
            menu.itemnumber=nil
            if search=='' then unfiltered_position=nil end
        end
        local function search_titles()
            ChapterSearch.prompt(host,menu,search,menu_current,function(query)
                if query=='' then
                    local position=unfiltered_position
                    filter(query,position and position.index,position and position.focus)
                    return
                end
                if search=='' then
                    local focused=menu:getFocusItem()
                    unfiltered_position={index=menu:getFirstVisibleItemIndex(),
                        focus=focused and focused.entry and focused.entry.chapter_index}
                end
                filter(query)
            end)
        end
        local function select_section()
            local choices,sections_menu={}
            for number,section in ipairs(sections) do
                choices[number]={text=T('%1. %2',section.order,section.title~='' and section.title or empty_title),
                    section_index=number,indent=section.depth and section.depth*indent,shortcut_icon_width=shortcut_width}
            end
            sections_menu=host:showList(_('Sections'),choices,nil,{on_choice=function(item)
                local number=type(item)=='table' and item.section_index
                if not number or choices[number]~=item or not menu_current() or not Popup.current(menu,sections_menu) then return end
                local index=sections[number].target
                Popup.close(menu)
                if search~='' then filter('',index)
                else menu:onGotoPage(menu:getPageNumber(index)) end
            end})
            if sections_menu then Popup.show(menu,sections_menu,function() end) end
        end
        menu.onLeftButtonTap=function()
            if not show_actions then search_titles();return true end
            if not menu_current() or menu._shelf_popup then return true end
            local actions
            local function action(callback)
                return function()
                    UIManager:nextTick(function()
                        if not menu_current() or not Popup.current(menu,actions) then return end
                        Popup.close(menu)
                        if callback then callback() end
                    end)
                end
            end
            local buttons={{{text=_('Find chapter'),callback=action(search_titles)}}}
            if sections then buttons[#buttons+1]={{text=_('Go to section'),callback=action(select_section)}} end
            if standard_available then
                buttons[#buttons+1]={{text=_('Read standard download'),callback=action(function()
                    local record=cached_standard_copy()
                    if not record then host:showInfo(_('No cached file.'));return end
                    M.cancel(host)
                    if origin_current() then open_cached_standard(record) end
                end)}}
            end
            buttons[#buttons+1]={{text=_('Cancel'),callback=action()}}
            actions=require('ui/widget/buttondialog'):new{title=_('E-Ink chapters'),buttons=buttons}
            Popup.show(menu,actions)
            return true
        end
        if initial_index then
            if adjacent_index and rows[adjacent_index].downloadable then menu.itemnumber=adjacent_index end
            menu:onGotoPage(menu:getPageNumber(initial_index))
        end
    end
    local function start_batch(range)
        ctx.batch_range=range
        ctx.batch_progress=nil
        ctx.phase='batch';host._native_direct_worker.timeout=3600
        local ok,widget=pcall(function() return require('weread.ui.download_dialog'):new{
            title=batch_title,
            description=_(repair_images and 'Improved chapters are saved as separate copies. Cancel to keep completed copies.'
                or 'Readable chapters are saved individually. Cancel to keep completed chapters.'),
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
    local function confirm_image_repair()
        local dialog
        dialog=require('ui/widget/confirmbox'):new{
            text=_('Retry missing images in downloaded chapters of this book? Improved chapters will be saved as new copies.'),
            ok_text=_('Recover images'),cancel_text=_('Cancel'),
            ok_callback=function() if take_confirmation(dialog) then start_batch() end end,
            cancel_callback=function() if take_confirmation(dialog) then M.cancel(host) end end,
        }
        show_confirmation(dialog)
    end
    local function show_batch_retry(reason)
        ctx.generation=ctx.generation+1
        close_busy()
        host._native_direct_worker.timeout=180
        local message,prompt
        if ctx.catalog then
            local range=ctx.batch_range
            local first,last=range and range.first or 1,range and range.last or #ctx.catalog.chapters
            message=_(reason=='rate_limited' and 'WeRead is limiting requests. Completed chapters were kept; try again later.'
                or 'The download connection was interrupted. Completed chapters were kept. Reconnect to retry.')
            prompt=repair_images and _('Retry recovering missing chapter images?') or T(_('Retry chapters %1–%2?'),first,last)
        else
            message=_(reason=='rate_limited' and 'WeRead is limiting requests. Please try again later.'
                or 'Could not load the E-Ink chapter list. Check the connection and try again.')
            prompt=_('Retry loading the chapter list?')
        end
        local dialog
        dialog=require('ui/widget/confirmbox'):new{
            text=message..'\n\n'..prompt,
            ok_text=_('Retry'),cancel_text=_('Cancel'),
            ok_callback=function()
                if not take_confirmation(dialog) then return end
                if not connected(host) then show_batch_retry('transport');return end
                ctx.recovery_attempted=nil
                load_chapters('catalog')
            end,
            cancel_callback=function() if take_confirmation(dialog) then M.cancel(host) end end,
        }
        show_confirmation(dialog)
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
    local function show_batch_plan(range,chapters)
        local dialog
        dialog=require('ui/widget/multiconfirmbox'):new{
            text=T(_('Continue downloading chapters %1–%2? Completed chapters will be reused.'),range.first,range.last),
            choice1_text=_('Continue download'),choice2_text=_('Choose new download'),cancel_text=_('Cancel'),
            choice1_callback=function() if take_confirmation(dialog) then start_batch(range) end end,
            choice2_callback=function() if take_confirmation(dialog) then show_batch_options(chapters) end end,
            cancel_callback=function() if take_confirmation(dialog) then M.cancel(host) end end,
        }
        show_confirmation(dialog)
    end
    local function open_saved(entry,is_current)
        local result,verified=Cache.open(host.settings,scope.vid,id,entry,is_current,true)
        if result then result.saved_entry=verified end
        return result
    end
    local function lookup_saved(is_current,complete_only)
        local chapter=ctx.chapter
        local rows=Cache.list(host.settings,scope.vid,id,is_current,chapter.chapterUid)
        if not rows then return nil,'storage' end
        local matches,saved={}
        for _,entry in ipairs(rows) do
            if matches_catalog(entry,chapter,ctx.catalog) then
                if not complete_only then
                    matches[#matches+1]=entry
                elseif entry.missing_images==0 and entry.chapter_idx==chapter.chapterIdx then
                    local verified=open_saved(entry,is_current)
                    if verified then
                        matches[#matches+1]=entry
                        saved=verified
                    end
                end
            end
        end
        if #matches>1 then return {copies=matches} end
        if #matches==0 then return nil,'not_saved' end
        saved=saved or open_saved(matches[1],is_current)
        if saved then return saved end
        return nil,'damaged'
    end
    local function read_cloud(auth,credentials)
        local ok,raw=pcall(auth._request,auth,'direct_progress',
            'https://i.weread.qq.com/book/getProgress?bookId='..id,nil,credentials,{2,3})
        if ok then return require('weread.lib.native_direct_resume').hint(raw,id) end
    end
    local function confirm_first_chapter(result)
        if not ctx.auto_open or ctx.auto_open.unstarted~=true or not result.path then return result end
        local latest
        if connected(host) and current() then
            local native=ctx.selected.native
            local auth=require('weread.lib.native_authorization'):new(host.client,{
                expected_vid=native.scope.vid,is_current=current})
            latest=read_cloud(auth,native.credentials)
            auth:cancel()
        end
        if latest and latest.unstarted==true then return result end
        return {error='new_book_position_changed',cloud_chapter=latest}
    end
    launch=function()
        local phase,saved_entry=ctx.phase,ctx.entry
        local is_current=phase_guard(phase)
        if not is_current() then M.cancel(host);return end
        ctx.generation=(ctx.generation or 0)+1
        local generation=ctx.generation
        local ok,started=pcall(host._native_direct_worker.start,host._native_direct_worker,function(progress)
            if phase=='batch' then
                local worker=require('weread.lib.native_direct_batch')
                if repair_images then
                    return worker.repair(host.client,host.settings,ctx.book,ctx.catalog,ctx.selected.native,current,progress)
                end
                local store=ctx.batch_store
                local record=store and store:begin(ctx.catalog,ctx.batch_range,ctx.batch_record,current)
                local result=worker.run(host.client,host.settings,ctx.book,ctx.catalog,
                    ctx.selected.native,current,progress,ctx.batch_range)
                if record then
                    if result.ok==true then store:remove(id,record,current) end
                    result.batch_record=record
                end
                return result
            end
            if phase=='offline_list' then
                local rows=Cache.list(host.settings,scope.vid,id,current)
                local catalog
                if rows and host.library_db then
                    pcall(require('weread.lib.native_direct_pending').mark,host.library_db,host.settings,scope,id,rows,current)
                    local entry=saved_catalog_entry(rows,anchor)
                    if entry then
                        local ok,snapshot=pcall(require('weread.lib.native_direct_catalog_store').read,
                            host.library_db,host.settings,host.client,scope,entry,current)
                        if ok and snapshot and snapshot.schema==2 then catalog=snapshot end
                    end
                end
                return rows and {rows=rows,catalog=catalog} or {error='storage'}
            elseif phase=='offline_open' then
                local result=open_saved(saved_entry,is_current)
                return result or {error='damaged'}
            elseif phase=='saved_matches' then
                local saved,reason=lookup_saved(is_current,false)
                return saved and confirm_first_chapter(saved) or {error=reason}
            end
            if phase=='catalog' then
                local native=ctx.selected.native
                local auth=require('weread.lib.native_authorization'):new(host.client,{
                    expected_vid=native.scope.vid,is_current=current})
                local good,value=pcall(require('weread.lib.native_book_catalog').read,auth,
                    native.credentials,id,'native_catalog')
                if not good then
                    auth:cancel()
                    local reason=type(value)=='string' and value:match('^native_auth/native_catalog_%a+/([%w_]+)$')
                    return {error=catalog_errors[reason] or 'unavailable'}
                end
                local result=project(value,id)
                if result and want_cloud_chapter then
                    result.cloud_chapter=read_cloud(auth,native.credentials)
                end
                auth:cancel()
                if result and host.library_db then
                    pcall(require('weread.lib.native_direct_catalog_store').save,host.library_db,host.settings,host.client,
                        scope,result,current)
                end
                if result and not ctx.catalog and ctx.batch_store then
                    result.batch_record=ctx.batch_store:read(id,current)
                end
                return result or {error='unavailable'}
            end
            if phase=='chapter' and (ctx.menu or ctx.auto_open) then
                local saved=lookup_saved(current,true)
                if saved then return confirm_first_chapter(saved) end
            end
            local expected={book_id=id,chapter_uid=ctx.chapter.chapterUid,book_version=ctx.catalog.version,
                reading_catalog_sha256=ctx.catalog.reading_digest,access_fingerprint=ctx.selected.native.fingerprint}
            local result,why=require('weread.lib.native_direct_reader').build(host.client,host.settings,
                ctx.book,ctx.chapter,expected,{is_current=current,allow_missing_images=true})
            return result and confirm_first_chapter(result) or {error=why or 'unavailable'}
        end,function(result)
            if host._native_direct_reading~=ctx or ctx.generation~=generation then return end
            if not is_current() then M.cancel(host);return end
            if phase=='batch' and type(result)=='table' and ctx.batch_store and ctx.batch_store:verified(result.batch_record,id) then
                ctx.batch_record=result.batch_record
            end
            local reason=type(result)=='table' and result.error
            if reason=='new_book_position_changed' and ctx.auto_open and ctx.auto_open.unstarted==true then
                ctx.auto_open=result.cloud_chapter or ctx.auto_open
                show_resume_catalog();return
            end
            if phase=='chapter' and (ctx.menu or ctx.auto_open or ctx.target) and (reason=='transport' or reason=='timeout') then
                begin_open('saved_matches');return
            end
            if ctx.target and phase=='saved_matches' and reason then
                load_saved_chapters('No saved copy matches this chapter. Connect to download it.',false,
                    'Chapter unavailable offline');return
            end
            if ctx.target and phase=='chapter' and (reason=='rate_limited' or reason=='catalog_changed') then
                local message=reason=='rate_limited' and 'WeRead is limiting requests. Please try again later.'
                    or 'The chapter list changed. Please open it again.'
                load_saved_chapters(message,false,message);return
            end
            if reason=='auth_expired' then renew();return end
            if ctx.batch and (phase=='batch' or phase=='catalog')
                and (reason=='transport' or reason=='rate_limited') then
                show_batch_retry(reason);return
            end
            if phase=='catalog' and reason then
                local interrupted=reason=='transport' or reason=='server_unavailable'
                catalog_unavailable(reason=='rate_limited' and 'WeRead is limiting requests. Please try again later.'
                    or interrupted and 'Could not load the E-Ink chapter list. Check the connection and try again.' or nil,interrupted)
                return
            end
            if reason=='rate_limited' then
                fail('WeRead is limiting requests. Please try again later.');return
            end
            if phase=='batch' then
                if reason=='catalog_changed' then fail('The chapter list changed. Please open it again.');return end
                if repair_images then
                    if reason=='changed' then
                        fail('The saved chapter changed or could not be verified. Existing files were kept.');return
                    end
                    local count=#ctx.catalog.chapters
                    local ok=type(result)=='table' and result.ok==true
                        and Protocol.integer(result.improved,0,count) and Protocol.integer(result.remaining,0,count)
                        and Protocol.integer(result.unverified,0,count)
                    M.cancel(host)
                    if ok then
                        host:showInfo(T(_('Images recovered in %1 chapters. %2 chapters still have missing images. %3 could not be verified.'),
                            result.improved,result.remaining,result.unverified))
                    else host:showInfo(_('Image recovery stopped. Existing and completed copies were kept.')) end
                    return
                end
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
                if not valid_saved_rows(rows,id,scope.vid) then fail(fallback_reason);return end
                if failed_copy then
                    for index,row in ipairs(rows) do
                        if row.key==failed_copy.key and row.copy==failed_copy.copy then table.remove(rows,index);break end
                    end
                end
                show_chapter_menu(rows,nil,result.catalog);return
            end
            if phase=='catalog' then
                local checked=type(result)=='table' and project({book_id=result.book_id,version=result.version,
                    reading_digest=result.reading_digest,reading_chapters=result.chapters},id)
                if not checked then catalog_unavailable();return end
                local previous=ctx.catalog
                ctx.catalog=checked
                if ctx.batch then
                    close_busy()
                    if previous then
                        if checked.version~=previous.version or checked.reading_digest~=previous.reading_digest
                            or #checked.chapters~=#previous.chapters then
                            fail('The chapter list changed. Please open it again.');return
                        end
                        start_batch(ctx.batch_range)
                    elseif repair_images then confirm_image_repair()
                    else
                        if ctx.batch_store and ctx.batch_store:verified(result.batch_record,id) then
                            ctx.batch_record=result.batch_record
                        end
                        local range=ctx.batch_store and ctx.batch_store:range(ctx.batch_record,checked)
                        if resume_plan then
                            if not ctx.batch_record or ctx.batch_record.revision~=resume_plan.revision
                                or ctx.batch_record.first~=resume_plan.first or ctx.batch_record.last~=resume_plan.last
                                or ctx.batch_record.digest~=resume_plan.digest or ctx.batch_record.version~=resume_plan.version
                                or ctx.batch_record.count~=resume_plan.count then
                                fail('This download plan changed. Reopen the unfinished downloads list.');return
                            end
                            if not range then fail('The chapter list changed. Please open it again.');return end
                        end
                        if range then show_batch_plan(range,checked.chapters)
                        else show_batch_options(checked.chapters) end
                    end
                    return
                end
                if ctx.target then
                    local wanted=ctx.target;local chapter=checked.chapters[wanted.order]
                    local neighbor=chapter and chapter[wanted.direction==1 and 'catalog_prev' or 'catalog_next']
                    if checked.version~=wanted.book_version or checked.reading_digest~=wanted.catalog_sha256
                        or #checked.chapters~=wanted.count or not chapter or chapter.chapterUid~=wanted.uid
                        or neighbor~=wanted.from_uid then
                        ctx.target=nil
                        catalog_notice=_('The chapter list changed. Choose a chapter from the updated list.')
                        show_chapter_menu(checked.chapters);return
                    end
                    if not chapter.downloadable then
                        ctx.target=nil
                        catalog_notice=_('The adjacent E-Ink chapter is unavailable.')
                        show_chapter_menu(checked.chapters);return
                    end
                    ctx.chapter=chapter
                    begin_open(connected(host) and 'chapter' or 'saved_matches');return
                end
                local cloud=result.cloud_chapter
                local chapter,position=direct_chapter(checked,cloud)
                if want_cloud_chapter and chapter and chapter.downloadable and connected(host) then
                    ctx.auto_open,ctx.chapter,ctx.cloud_target=cloud,chapter,position
                    begin_open('chapter');return
                end
                show_chapter_menu(checked.chapters,nil,nil,cloud);return
            end
            if (phase=='saved_matches' or phase=='chapter') and type(result)=='table' then
                if phase=='saved_matches' and result.error=='not_saved' then
                    if standard_read and ctx.auto_open then fail(nil,nil,true)
                    else fail('No saved copy matches this chapter. Connect to download it.') end
                    return
                end
                if reason=='unsupported_format' then
                    fail('This book format is unavailable in E-Ink reading.',nil,true);return
                end
                if result.copies~=nil then
                    local rows=result.copies
                    if not valid_saved_rows(rows,id,scope.vid) or #rows<2 then fail();return end
                    for _,entry in ipairs(rows) do
                        if not matches_catalog(entry,ctx.chapter,ctx.catalog)
                            or phase=='chapter' and (entry.missing_images~=0 or entry.chapter_idx~=ctx.chapter.chapterIdx) then
                            fail();return
                        end
                    end
                    show_saved_copies(rows,phase=='chapter');return
                end
            end
            local version=phase=='offline_open' and saved_entry.book_version or ctx.catalog.version
            if type(result)~='table' or not require('weread.lib.native_direct_path').contains(host.settings,result.path)
                or not hash(result.source_sha256) or result.book_version~=version
                or not Protocol.integer(result.missing_images,0,64) then
                fail(reason=='damaged' and 'The saved E-Ink chapter is damaged or has changed. The file was kept.'
                    or reason=='catalog_changed' and 'The chapter list changed. Please open it again.' or nil,
                    reason=='catalog_changed');return
            end
            local path=result.path
            local handoff
            if ctx.cloud_target and current() and connected(host) then
                handoff=require('weread.ui.native_direct_cloud_open').for_catalog(host,result,ctx.catalog,
                    ctx.chapter,ctx.cloud_target,ctx.selected.native)
            end
            if result.saved_entry then
                handoff=require('weread.ui.native_home_resume').for_verified_open(path,result.saved_entry,scope,handoff)
            end
            M.cancel(host)
            host:openFile(path,handoff)
        end,phase=='batch' and function(value)
            if host._native_direct_reading~=ctx or ctx.generation~=generation then return end
            if not current() or ctx.busy~=host.busy_message then M.cancel(host);return end
            if type(value)=='number' and value>=0 and value<=99 and value%1==0
                and value>(ctx.batch_progress or -1) then
                ctx.batch_progress=value
                ctx.busy:reportProgress(value)
            end
        end or nil)
        if not ok or not started then fail() end
    end
    load_chapters(offline and 'offline_list' or 'catalog')
    return host._native_direct_reading==ctx
end
return M

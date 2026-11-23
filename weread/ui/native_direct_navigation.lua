-- Navigation for isolated native chapters. Never grant Web position authority.
local UI=require('ui/uimanager')
local Cache=require('weread.lib.native_direct_cache')
local Path=require('weread.lib.native_direct_path')
local _=require('weread.lib.plugin_util').tr
local M={}

function M.cancel(host)
    local ctx=host._native_direct_navigation
    if not ctx then return end
    host._native_direct_navigation=nil
    if host._native_direct_navigation_worker then host._native_direct_navigation_worker:cancel() end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
    ctx.busy=nil
    local menu=ctx.menu;ctx.menu=nil
    if menu then UI:close(menu) end
end

function M.start(host,direction,notes)
    if notes~=nil and notes~='marks' and notes~='bookmarks' and notes~='thoughts' then return false end
    local reader=host.ui;local document=reader and reader.document
    local path=document and document.file
    if not Path.contains(host.settings,path) then return false end
    local scope=host.settings:get_auth_scope()
    if not scope or not host.settings:auth_scope_matches(scope) then
        host:showInfo(_('Sign in to the account that saved these E-Ink chapters.'));return true
    end
    if notes and (not host.library_db or not host.library_db:accountKey()) then
        host:showInfo(_('Sign in to the account that saved these E-Ink chapters.'));return true
    end
    M.cancel(host)
    local ctx={reader=reader,document=document,path=path,scope=scope,session=host._reader_session_gen or 0,
        account=host.library_db and host.library_db:accountKey()}
    host._native_direct_navigation=ctx
    local function current()
        return host._native_direct_navigation==ctx and host.ui==reader and reader.document==document and document.file==path
            and (host._reader_session_gen or 0)==ctx.session and host.settings:auth_scope_matches(scope)
            and (not host.library_db or host.library_db:accountKey()==ctx.account)
    end
    local function busy(label)
        host:showBusy(_(label),function() M.cancel(host) end);ctx.busy=host.busy_message
    end
    local function close_busy()
        if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
        ctx.busy=nil
    end
    local function fail(message)
        if host._native_direct_navigation~=ctx then return end
        local live=current();M.cancel(host)
        if live then host:showInfo(_(message)) end
    end
    local function details()
        if not current() then return end
        local id=ctx.entry.book_id
        local book=host.settings.get_book and host.settings:get_book(id) or nil
        if type(book)~='table' or tostring(book.book_id or book.bookId or '')~=id then
            book={book_id=id,title=id,author=''}
        end
        M.cancel(host)
        host:showBookMenu(book)
        return book,host._book_detail_view
    end
    if not host._native_direct_navigation_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
            scheduler=UI,codec=host.client,max_bytes=8*1024*1024,timeout=180} end)
        if not ok then fail('Could not check this saved E-Ink chapter.');return true end
        host._native_direct_navigation_worker=worker
    end
    local worker=host._native_direct_navigation_worker
    local function run(task,done)
        ctx.generation=(ctx.generation or 0)+1
        local generation=ctx.generation
        local called,started=pcall(worker.start,worker,task,function(value)
            if host._native_direct_navigation~=ctx or ctx.generation~=generation then return end
            if not current() then M.cancel(host);return end
            done(value)
        end)
        if not called or not started then fail('Could not check this saved E-Ink chapter.') end
    end
    local function step(which)
        if not current() then M.cancel(host);return end
        local entry=ctx.entry
        if not entry.catalog_sha256 then
            fail('Chapter order is unavailable. Reopen this chapter online to update it.');return
        end
        local uid=which==1 and entry.catalog_next or entry.catalog_prev
        if not uid then
            fail(which==1 and 'You have reached the last chapter.' or 'You have reached the first chapter.');return
        end
        busy('Checking adjacent saved chapter...')
        local function source_unchanged()
            local source=Cache.identify(host.settings,scope.vid,path,current)
            return source and source.key==entry.key and source.copy==entry.copy
                and source.source_sha256==entry.source_sha256 and source.book_version==entry.book_version
                and source.catalog_sha256==entry.catalog_sha256 and source.catalog_order==entry.catalog_order
                and source.catalog_count==entry.catalog_count and source.catalog_prev==entry.catalog_prev
                and source.catalog_next==entry.catalog_next
        end
        local function matches(candidate)
            local reciprocal=which==1 and candidate.catalog_prev or candidate.catalog_next
            return candidate.chapter_uid==uid and candidate.book_version==entry.book_version
                and candidate.catalog_sha256==entry.catalog_sha256 and candidate.catalog_count==entry.catalog_count
                and candidate.catalog_order==entry.catalog_order+which and reciprocal==entry.chapter_uid
        end
        local function finish(value)
            close_busy()
            if type(value)~='table' or not Path.contains(host.settings,value.path)
                or value.book_version~=entry.book_version or type(value.source_sha256)~='string'
                or #value.source_sha256~=64 or not value.source_sha256:match('^[a-f0-9]+$') then
                fail('The saved chapter changed or could not be verified. Existing files were kept.');return
            end
            local destination=value.path
            M.cancel(host);host:openFile(destination)
        end
        run(function()
            if not source_unchanged() then return {error='changed'} end
            local rows=Cache.list(host.settings,scope.vid,entry.book_id,current)
            if not rows then return {error='storage'} end
            local choices={}
            for _,candidate in ipairs(rows) do
                if matches(candidate) then choices[#choices+1]=candidate end
            end
            if #choices>1 then return {choices=choices} end
            if #choices==1 then
                local saved=Cache.open(host.settings,scope.vid,entry.book_id,choices[1],current)
                if saved then return saved end
            end
            return {error='not_saved'}
        end,function(value)
            close_busy()
            if type(value)=='table' and value.error=='not_saved' then
                local online=host.isNetworkConnected and host:isNetworkConnected()
                    or not host.isNetworkConnected and host:isNetworkOnline()
                if not online then fail('The adjacent chapter is not saved. Connect to download it.');return end
                local target={uid=uid,from_uid=entry.chapter_uid,catalog_sha256=entry.catalog_sha256,
                    book_version=entry.book_version,count=entry.catalog_count,order=entry.catalog_order+which,direction=which}
                local book,view=details()
                if book and view then require('weread.ui.native_direct_reading').start(host,book,view,{target=target}) end
                return
            end
            if type(value)=='table' and type(value.choices)=='table' then
                local choices=value.choices;local seen={}
                if #choices<2 or #choices>Cache.MAX_ENTRIES then fail('The saved chapter changed or could not be verified. Existing files were kept.');return end
                local count=0
                for key in pairs(choices) do
                    if type(key)~='number' or key%1~=0 or key<1 or key>#choices then
                        fail('The saved chapter changed or could not be verified. Existing files were kept.');return
                    end
                    count=count+1
                end
                if count~=#choices then fail('The saved chapter changed or could not be verified. Existing files were kept.');return end
                for _,candidate in ipairs(choices) do
                    if not Cache.valid_entry(candidate,entry.book_id,scope.vid) or not matches(candidate) then
                        fail('The saved chapter changed or could not be verified. Existing files were kept.');return
                    end
                    local id=candidate.key..':'..tostring(candidate.copy)
                    if seen[id] then fail('The saved chapter changed or could not be verified. Existing files were kept.');return end
                    seen[id]=true
                end
                local labels=require('weread.ui.native_direct_copies').labels(choices);local items={};local menu
                for index,candidate in ipairs(choices) do
                    local selected=candidate
                    items[index]={text=labels[index],callback=function()
                        if not current() or ctx.menu~=menu then return end
                        ctx.menu=nil;UI:close(menu);busy('Checking saved E-Ink chapter...')
                        run(function()
                            if not source_unchanged() or not matches(selected) then return {error='changed'} end
                            return Cache.open(host.settings,scope.vid,entry.book_id,selected,current) or {error='changed'}
                        end,finish)
                    end}
                end
                menu=host:showList(_('Choose a saved chapter copy'),items,nil,
                    {subtitle=_('Each copy keeps its own reading position. Reopen online to retry missing images.')})
                if not menu then fail('The saved chapter changed or could not be verified. Existing files were kept.');return end
                ctx.menu=menu
                local closed=menu.onCloseWidget
                menu.onCloseWidget=function(widget,...)
                    if ctx.menu==widget and host._native_direct_navigation==ctx then ctx.menu=nil;M.cancel(host) end
                    if closed then return closed(widget,...) end
                end
                menu.close_callback=function()
                    if ctx.menu==menu and host._native_direct_navigation==ctx then ctx.menu=nil;M.cancel(host) end
                end
                return
            end
            finish(value)
        end)
    end
    local function menu()
        close_busy()
        require('weread.ui.end_of_book_dialog').show({show_chapter_nav=true,show_previous_chapter=true,
            show_next_chapter=true,enable_chapter_list=true,enable_previous_chapter=true,
            enable_next_chapter=true,enable_book_details=true,show_sync_row=false,
            enable_search_current=type(reader.search)=='table' and type(reader.search.onShowFulltextSearchInput)=='function',
            enable_search_book=true,enable_search_cached=true}, {
            on_chapter_list=function()
                local book,view=details()
                if book and view then require('weread.ui.native_direct_reading').start(host,book,view) end
            end,
            on_previous=function() step(-1) end,on_next=function() step(1) end,
            on_book_details=function() details() end,
            on_native_position_check=function()
                if not current() then return end
                local entry=ctx.entry;M.cancel(host)
                require('weread.ui.native_direct_position').start(host,entry)
            end,
            on_native_cloud_position=function()
                if not current() then return end
                local entry=ctx.entry;M.cancel(host)
                require('weread.ui.native_direct_position').start(host,entry,{cloud=true})
            end,
            on_native_upload_position=function()
                if not current() then return end
                local entry=ctx.entry;M.cancel(host)
                require('weread.ui.native_direct_position').start(host,entry,{upload=true})
            end,
            on_native_bookmark=function()
                if not current() then return end
                M.cancel(host)
                require('weread.ui.selection_thought').open_bookmark(host)
            end,
            on_native_refresh_images=ctx.entry.missing_images>0 and function()
                if not current() then return end
                local entry=ctx.entry;M.cancel(host)
                require('weread.ui.native_direct_image_refresh').start(host,entry)
            end or nil,
            on_bookshelf=function() if current() then M.cancel(host);host:showBookshelf() end end,
            on_search=function() if current() then M.cancel(host);host:showSearch() end end,
            on_search_current=function() if current() then reader.search:onShowFulltextSearchInput() end end,
            on_search_book=function()
                if not current() then return end
                local entry=ctx.entry;M.cancel(host)
                require('weread.ui.book_search').open(host,entry.book_id,nil,entry.chapter_uid,entry)
            end,
            on_search_cached=function()
                if not current() then return end
                local entry=ctx.entry;M.cancel(host)
                require('weread.ui.native_direct_search').open(host,entry)
            end,
            on_read_stats=function() if current() then M.cancel(host);host:showReadStats() end end,
            on_reader_progress=function() if current() then require('weread.ui.reader_progress').show(host,{is_current=current}) end end,
            on_reader_typography=function() if current() then require('weread.ui.reader_typography').show(host) end end,
            on_reader_display=function() if current() then require('weread.ui.reader_display').show(host,{is_current=current}) end end,
            on_delayed_screenshot=function() if current() then host:onShowWeReadDelayedScreenshot() end end,
            on_close_book=function()
                if not current() then return end
                M.cancel(host);reader:onClose()
                if path and reader.showFileManager then reader:showFileManager(path) end
            end,
        })
    end
    busy('Checking saved E-Ink chapter...')
    run(function()
        local entry=Cache.identify(host.settings,scope.vid,path,current)
        return entry and {entry=entry} or {error='invalid'}
    end,function(value)
        if type(value)~='table' or type(value.entry)~='table'
            or not Cache.valid_entry(value.entry,value.entry.book_id,scope.vid) then
            fail('The saved chapter changed or could not be verified. Existing files were kept.');return
        end
        ctx.entry=value.entry
        if notes then
            local id=ctx.entry.book_id
            local identity=require('weread.lib.book_file_identity').read_document(document,id)
            if identity.book_id~=id or identity.file_id~=ctx.entry.file_id or identity.book_version~=ctx.entry.book_version then
                fail('The saved chapter changed or could not be verified. Existing files were kept.');return
            end
            local method=notes=='marks' and 'showMyCloudMarks' or notes=='bookmarks' and 'showMyCloudBookmarks' or 'showMyCloudThoughts'
            close_busy();M.cancel(host)
            if type(host[method])=='function' then host[method](host,id) end
        elseif direction==1 or direction==-1 then close_busy();step(direction) else menu() end
    end)
    return true
end
function M.open_notes(host,variant)
    if variant~='marks' and variant~='bookmarks' and variant~='thoughts' then return false end
    return M.start(host,nil,variant)
end
return M

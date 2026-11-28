-- Navigation for isolated native chapters. Never grant Web position authority.
local UI=require('ui/uimanager')
local Cache=require('weread.lib.native_direct_cache')
local Path=require('weread.lib.native_direct_path')
local _=require('weread.lib.plugin_util').tr
local M={}

local function connected(host)
    return host.isNetworkConnected and host:isNetworkConnected()
        or not host.isNetworkConnected and host:isNetworkOnline()
end

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
    if notes~=nil and notes~='marks' and notes~='bookmarks' and notes~='thoughts'
        and notes~='cloud' and notes~='upload' then return false end
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
    local context
    if notes=='cloud' or notes=='upload' then
        context=require('weread.lib.source_context')
        ctx.location=context.location(document,reader.view and reader.view.view_mode or 'page')
        if not ctx.location then host:showInfo(_('The current reading page could not be verified.'));return false end
    end
    host._native_direct_navigation=ctx
    local function current()
        return not host._weread_suspended and host._native_direct_navigation==ctx
            and host.ui==reader and reader.document==document and document.file==path
            and (host._reader_session_gen or 0)==ctx.session and host.settings:auth_scope_matches(scope)
            and (not host.library_db or host.library_db:accountKey()==ctx.account)
    end
    local function page_current()
        return not ctx.location or context.same_location(ctx.location,
            context.location(document,reader.view and reader.view.view_mode or 'page'))
    end
    local function busy(label,cancel)
        local dialog
        host:showBusy(_(label),function()
            if host._native_direct_navigation~=ctx or ctx.busy~=dialog then return end
            if cancel then cancel() else M.cancel(host) end
        end)
        dialog=host.busy_message;ctx.busy=dialog
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
    local function active_book()
        local id=ctx.entry.book_id
        local book=host.settings.get_book and host.settings:get_book(id) or nil
        if type(book)~='table' or tostring(book.book_id or book.bookId or '')~=id then
            return {book_id=id,title=id,author=''}
        end
        return book
    end
    local function choose_chapter(options)
        if not current() then return end
        local book=active_book()
        options.from_reader=true
        M.cancel(host)
        require('weread.ui.native_direct_reading').start(host,book,reader,options)
    end
    local function choose_saved(notice,failed_copy)
        choose_chapter({anchor=ctx.entry,cached=true,offline_notice=notice,failed_copy=failed_copy})
    end
    if not host._native_direct_navigation_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
            scheduler=UI,codec=host.client,max_bytes=8*1024*1024,timeout=180} end)
        if not ok then fail('Could not check this saved E-Ink chapter.');return true end
        host._native_direct_navigation_worker=worker
    end
    local worker=host._native_direct_navigation_worker
    local function run(task,done,optional)
        ctx.generation=(ctx.generation or 0)+1
        local generation=ctx.generation
        local function complete(value)
            if host._native_direct_navigation~=ctx or ctx.generation~=generation then return end
            if not current() or not page_current() then M.cancel(host);return end
            done(value)
        end
        local called,started=pcall(worker.start,worker,task,complete)
        if not called or not started then
            if optional then complete(nil) else fail('Could not check this saved E-Ink chapter.') end
        end
    end
    local function step(which)
        if not current() then M.cancel(host);return end
        local entry=ctx.entry
        if not entry.catalog_sha256 then
            if connected(host) then
                choose_chapter({anchor=entry,adjacent_direction=which})
            else
                choose_saved('Chapter order is unavailable offline')
            end
            return
        end
        local uid=entry[which==1 and 'catalog_next' or 'catalog_prev']
        if not uid then
            fail(which==1 and 'You have reached the last chapter.' or 'You have reached the first chapter.');return
        end
        local cannot_verify='The saved chapter changed or could not be verified. Existing files were kept.'
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
            local reciprocal=candidate[which==1 and 'catalog_prev' or 'catalog_next']
            return candidate.chapter_uid==uid and candidate.book_version==entry.book_version
                and candidate.catalog_sha256==entry.catalog_sha256 and candidate.catalog_count==entry.catalog_count
                and candidate.catalog_order==entry.catalog_order+which and reciprocal==entry.chapter_uid
        end
        local function finish(value)
            close_busy()
            if type(value)=='table' and value.error=='copy_changed' and ctx.menu then
                host:showInfo(_(cannot_verify));return
            end
            if type(value)~='table' or not Path.contains(host.settings,value.path)
                or value.book_version~=entry.book_version or type(value.source_sha256)~='string'
                or #value.source_sha256~=64 or not value.source_sha256:match('^[a-f0-9]+$') then
                fail(cannot_verify);return
            end
            local destination=value.path
            M.cancel(host);host:openFile(destination)
        end
        run(function()
            if not source_unchanged() then return {error='changed'} end
            local rows=Cache.list(host.settings,scope.vid,entry.book_id,current,uid)
            if not rows then return {error='storage'} end
            local choices={}
            for _,candidate in ipairs(rows) do
                if matches(candidate) then choices[#choices+1]=candidate end
            end
            if #choices>1 then return {choices=choices} end
            if #choices==1 then
                return Cache.open(host.settings,scope.vid,entry.book_id,choices[1],current)
                    or {error='copy_changed',failed_copy=choices[1]}
            end
            return {error='not_saved'}
        end,function(value)
            close_busy()
            local reason=type(value)=='table' and value.error
            if reason=='not_saved' or reason=='copy_changed' then
                if not connected(host) then
                    choose_saved('Chapter unavailable offline',value.failed_copy)
                    return
                end
                local target={uid=uid,from_uid=entry.chapter_uid,catalog_sha256=entry.catalog_sha256,
                    book_version=entry.book_version,count=entry.catalog_count,order=entry.catalog_order+which,direction=which}
                choose_chapter({anchor=entry,target=target,failed_copy=value.failed_copy})
                return
            end
            if type(value)=='table' and type(value.choices)=='table' then
                local choices=value.choices;local seen={}
                if #choices<2 or #choices>Cache.MAX_ENTRIES then fail(cannot_verify);return end
                local count=0
                for key in pairs(choices) do
                    if type(key)~='number' or key%1~=0 or key<1 or key>#choices then
                        fail(cannot_verify);return
                    end
                    count=count+1
                end
                if count~=#choices then fail(cannot_verify);return end
                for _,candidate in ipairs(choices) do
                    if not Cache.valid_entry(candidate,entry.book_id,scope.vid) or not matches(candidate) then
                        fail(cannot_verify);return
                    end
                    local id=candidate.key..':'..tostring(candidate.copy)
                    if seen[id] then fail(cannot_verify);return end
                    seen[id]=true
                end
                local labels=require('weread.ui.native_direct_copies').labels(choices);local items={};local menu
                for index,label in ipairs(labels) do items[index]={text=label,copy_index=index} end
                menu=host:showList(_('Choose a saved chapter copy'),items,nil,{
                    subtitle=_('Each copy keeps its own reading position. Reopen online to retry missing images.'),
                    on_choice=function(item)
                        local index=type(item)=='table' and item.copy_index
                        if ctx.menu~=menu or ctx.busy or not index or items[index]~=item then return end
                        if not current() then M.cancel(host);return end
                        local selected=choices[index]
                        busy('Checking saved E-Ink chapter...',function()
                            if not current() then M.cancel(host);return end
                            ctx.generation=ctx.generation+1
                            worker:cancel()
                            close_busy()
                        end)
                        run(function()
                            if not source_unchanged() or not matches(selected) then return {error='changed'} end
                            return Cache.open(host.settings,scope.vid,entry.book_id,selected,current) or {error='copy_changed'}
                        end,finish)
                    end,
                })
                if not menu then fail(cannot_verify);return end
                ctx.menu=menu
                local closed=menu.onCloseWidget
                menu.onCloseWidget=function(widget,...)
                    if ctx.menu==widget and host._native_direct_navigation==ctx then ctx.menu=nil;M.cancel(host) end
                    if closed then return closed(widget,...) end
                end
                return
            end
            finish(value)
        end)
    end
    local function show_progress()
        if not current() or ctx.busy or ctx.progress_pending then return end
        local entry=ctx.entry
        local catalog=require('weread.lib.native_direct_catalog_store')
        local function show(weights)
            require('weread.ui.reader_progress').show(host,{is_current=current,single_chapter=true,
                chapter_number=entry.catalog_order,chapter_count=entry.catalog_count,
                previous_action=(entry.catalog_prev or not entry.catalog_sha256) and function() step(-1) end or nil,
                next_action=(entry.catalog_next or not entry.catalog_sha256) and function() step(1) end or nil,
                estimate=function(percent) return catalog.estimate_from_weights(weights,percent) end})
        end
        if not entry.catalog_sha256 or not ctx.account then show();return end
        local pending={}
        ctx.progress_pending=pending
        -- Most reads finish on the first worker poll. Avoid painting a notice
        -- between the two panels unless the storage read actually takes time.
        UI:scheduleIn(.4,function()
            if ctx.progress_pending==pending and current() then busy('Checking saved E-Ink chapter...') end
        end)
        run(function()
            local weights=catalog.read_weights(host.library_db,host.settings,host.client,scope,entry,current)
            return {weights=weights}
        end,function(value)
            if ctx.progress_pending~=pending then return end
            ctx.progress_pending=nil
            close_busy()
            show(type(value)=='table' and value.weights or nil)
        end,true)
    end
    local function menu()
        close_busy()
        local known_order=ctx.entry.catalog_sha256~=nil
        require('weread.ui.end_of_book_dialog').show({show_chapter_nav=true,show_previous_chapter=true,
            show_next_chapter=true,enable_chapter_list=true,enable_previous_chapter=not known_order or ctx.entry.catalog_prev~=nil,
            enable_next_chapter=not known_order or ctx.entry.catalog_next~=nil,enable_book_details=true,show_sync_row=false,
            close_to_home=ctx.account~=nil,
            enable_search_current=type(reader.search)=='table' and type(reader.search.onShowFulltextSearchInput)=='function',
            enable_search_book=true,enable_search_cached=true}, {
            on_chapter_list=function() choose_chapter({anchor=ctx.entry}) end,
            on_saved_chapters=function() choose_chapter({anchor=ctx.entry,cached=true}) end,
            on_download_chapters=function() choose_chapter({anchor=ctx.entry,batch=true}) end,
            on_previous=function() step(-1) end,on_next=function() step(1) end,
            on_book_details=function()
                if not current() then return end
                local book=active_book()
                M.cancel(host)
                host:showBookMenu(book)
            end,
            on_shelf_status=ctx.account and function()
                if not current() then return end
                local id=ctx.entry.book_id
                M.cancel(host)
                host:showShelfState(id)
            end or nil,
            on_native_position_check=function()
                if not current() then return end
                local entry=ctx.entry;M.cancel(host)
                require('weread.ui.native_direct_position').start(host,entry)
            end,
            on_native_offline_reminder=function()
                if not current() then return end
                local original=ctx.entry
                busy('Checking saved E-Ink chapter...')
                run(function()
                    local entry=Cache.identify(host.settings,scope.vid,path,current)
                    if not entry then return {error='invalid'} end
                    local pending=require('weread.lib.native_direct_pending').read(host.library_db,host.settings,scope,entry,current)
                    return {entry=entry,pending=pending}
                end,function(value)
                    local entry=type(value)=='table' and value.entry
                    if not Cache.valid_entry(entry,original.book_id,scope.vid) or entry.chapter_uid~=original.chapter_uid
                        or entry.book_version~=original.book_version or entry.file_id~=original.file_id
                        or entry.source_sha256~=original.source_sha256 or entry.key~=original.key or entry.copy~=original.copy then
                        fail('The saved chapter changed or could not be verified. Existing files were kept.');return
                    end
                    close_busy();M.cancel(host)
                    require('weread.ui.native_direct_reconnect').open_manual(host,entry,value.pending)
                end)
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
            on_reader_progress=show_progress,
            on_reader_typography=function() if current() then require('weread.ui.reader_typography').show(host) end end,
            on_reader_display=function() if current() then require('weread.ui.reader_display').show(host,{is_current=current}) end end,
            on_delayed_screenshot=function() if current() then host:onShowWeReadDelayedScreenshot() end end,
            on_close_book=function()
                if not current() then return end
                require('weread.ui.native_home_resume').remember(host,ctx.entry,scope)
                M.cancel(host)
                require('weread.ui.reader_exit').close(host,reader,ctx.account and scope or nil)
            end,
        })
    end
    busy('Checking saved E-Ink chapter...')
    run(function()
        local entry=Cache.identify(host.settings,scope.vid,path,current)
        if not entry then return {error='invalid'} end
        return {entry=entry}
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
            close_busy();M.cancel(host)
            if notes=='cloud' or notes=='upload' then
                require('weread.ui.native_direct_position').start(host,ctx.entry,
                    notes=='cloud' and {cloud=true} or {upload=true})
            else
                local method=notes=='marks' and 'showMyCloudMarks' or notes=='bookmarks' and 'showMyCloudBookmarks' or 'showMyCloudThoughts'
                if type(host[method])=='function' then host[method](host,id) end
            end
        elseif direction==1 or direction==-1 then close_busy();step(direction) else menu() end
    end)
    return true
end
function M.open_notes(host,variant)
    if variant~='marks' and variant~='bookmarks' and variant~='thoughts' then return false end
    return M.start(host,nil,variant)
end
function M.open_position(host,action)
    if action~='cloud' and action~='upload' then return false end
    return M.start(host,nil,action)
end
return M

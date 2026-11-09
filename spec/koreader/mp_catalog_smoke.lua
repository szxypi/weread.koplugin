-- Real first-page HTTP, large pipe, native lists and per-book file persistence.
return function(plugin,count,flush,home,pump,control)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local Content=require('weread.lib.content')
    local Model=require('weread.lib.mp_catalog')
    local Settings=require('weread.lib.settings')
    local socket=require('socket')
    local ffi=require('ffi')
    local settings,client=plugin.settings,plugin.client
    local parent=tonumber(ffi.C.getpid())
    local read,request,open=Model.read,client.request,plugin.openFile
    local opened
    local renewal=count('/web/login/renewal');local writes=count('/web/book/read')
    local cookies=require('weread.lib.cookie').to_header(settings:get('cookies'))
    local old={reviewId='cache-fixture-a/b',title='之前保存的文章',createTime=1700000000}
    local function setup(id)
        local book={book_id='MP_WXS_'..id,title='合成公众号目录',cache_dir=settings.data_dir..'/catalog-'..id,
            progress=.25,pending_upload_position={offset=4},mp_articles={old},mp_articles_time=123}
        local path=Content.save_mp_article_html(settings,book,old,'<p>之前保存的合成正文</p>')
        local books=settings:get('books',{});books[book.book_id]=book;settings:set('books',books);settings:flush()
        return book,path
    end
    local function contents(path) local file=assert(io.open(path,'rb'));local value=file:read('*a');file:close();return value end
    local function close_info()
        local top=UIManager:getTopmostVisibleWidget();if top and top~=plugin.ui and top.text then UIManager:close(top) end
    end
    Model.read=function(...)
        assert(tonumber(ffi.C.getpid())~=parent,'catalog read ran on UI thread')
        socket.sleep(.35);return read(...)
    end
    client.request=function(self,opts)
        if opts.diagnostic_api=='mp_catalog' then
            assert(tonumber(ffi.C.getpid())~=parent and opts.method=='GET' and opts.skip_cookie and opts.persist_response_cookies==false,'catalog transport blocked UI or mutated cookies')
        end
        return request(self,opts)
    end
    plugin.openFile=function(_self,path) opened=path end
    local book,path=setup('900096');local previous=contents(path)
    local responsive=false;local gets=count('/web/mp/articles')
    assert(plugin:fetchMPArticles(book));local first=plugin.mp_catalog_job
    UIManager:scheduleIn(.1,function()
        responsive=plugin.mp_catalog_job==first
        local books=settings:get('books',{});books[book.book_id].progress=.6;books[book.book_id].pending_upload_position.offset=19
        settings:set('books',books);settings:flush()
        UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-catalog-loading.png')
    end)
    pump(function() return not plugin.mp_catalog_job end)
    assert(responsive and count('/web/mp/articles')==gets+1 and not plugin.busy_message,'catalog not responsive or repeated GET')
    local menu=assert(plugin._mp_article_list_view)
    assert(menu.item_table[1].text=='合成目录文章甲' and #menu.item_table==5
        and menu.item_table[3].text==require('weread.lib.i18n').tr('Article cache and versions'),'catalog fields/rows or cache toolbar not shown')
    local record=Settings:new():get('books',{})[book.book_id]
    assert(#record.mp_articles==2 and not record.mp_articles[1].private and record.progress==.6 and record.pending_upload_position.offset==19,'catalog not persisted or overwrote newer reading state')
    menu:onMenuSelect(menu.item_table[1]);assert(opened==path and contents(path)==previous,'refreshed list lost existing identity cache')
    plugin:showMPAccount(book);assert(plugin._mp_article_list_view.item_table[1].text=='合成目录文章甲','saved catalog did not reopen')
    -- Existing offline list stays visible; no DNS or HTTP work is scheduled.
    local connected=plugin.isNetworkConnected;plugin.isNetworkConnected=function() return false end
    local old_menu=plugin._mp_article_list_view;gets=count('/web/mp/articles')
    assert(not plugin:fetchMPArticles(book) and not plugin.mp_catalog_job and plugin._mp_article_list_view==old_menu and count('/web/mp/articles')==gets,'offline refresh discarded existing menu')
    plugin.isNetworkConnected=connected;close_info()
    -- A complete empty array differs from malformed/missing/oversized data.
    for _,id in ipairs({'900094','900093','900092','900091','900090'}) do
        local sample,saved_path=setup(id);local saved_body=contents(saved_path);gets=count('/web/mp/articles')
        assert(plugin:fetchMPArticles(sample));pump(function() return not plugin.mp_catalog_job end)
        local saved=settings:get('books',{})[sample.book_id]
        assert(#saved.mp_articles==1 and saved.mp_articles_time==123 and contents(saved_path)==saved_body,'invalid response erased saved rows/files: '..id)
        assert(plugin._mp_article_list_view and plugin._mp_article_list_view.item_table[1].text==old.title,'failed refresh did not restore saved list')
        assert(count('/web/mp/articles')==gets+(id=='900092' and 2 or 1),'failed catalog exceeded its one login recovery read')
        close_info();plugin:closeWeReadUI()
    end
    local empty,empty_path=setup('900095');local empty_body=contents(empty_path)
    plugin:fetchMPArticles(empty);pump(function() return not plugin.mp_catalog_job end)
    menu=assert(plugin._mp_article_list_view)
    assert(menu.item_table[1].text==require('weread.lib.i18n').tr('No articles.') and menu.item_table[1].select_enabled==false
        and #Settings:new():get('books',{})[empty.book_id].mp_articles==0 and contents(empty_path)==empty_body,'valid empty catalog not labelled/persisted or deleted cached body')
    gets=count('/web/mp/articles');plugin.isNetworkConnected=function() return false end
    plugin:showMPAccount(empty);plugin.isNetworkConnected=connected
    assert(not plugin.mp_catalog_job and count('/web/mp/articles')==gets and plugin._mp_article_list_view.item_table[1].text==require('weread.lib.i18n').tr('No articles.'),'saved empty catalog did not reopen offline')
    -- More than one kernel pipe buffer reaches the parent intact and paginates.
    local large=setup('900089');plugin:fetchMPArticles(large);pump(function() return not plugin.mp_catalog_job end)
    menu=assert(plugin._mp_article_list_view)
    assert(#menu.item_table==104 and #settings:get('books',{})[large.book_id].mp_articles==100,'large catalog pipe truncated rows')
    assert(menu.item_table[101].text==require('weread.lib.i18n').tr('First 100 articles loaded.') and menu.item_table[101].select_enabled==false,'first-page bound not visible')
    assert(menu.page_num>1);menu:onGotoPage(menu.page_num);UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-catalog-first-batch.png')
    -- Every ownership change cancels or discards the old result without a save.
    for _,change in ipairs({'dismiss','close','suspend','session','epoch','cookie','header','cache','move'}) do
        local sample=setup('900096');assert(plugin:fetchMPArticles(sample))
        local snapshot=settings:get('books',{})[sample.book_id].mp_articles[1]
        local key=settings:get('cookies');local ticket=settings:get('wr_ticket','');local root=settings.cache_dir
        UIManager:scheduleIn(.1,function()
            if change=='dismiss' then
                local busy=assert(plugin.busy_message);busy:onAnyKeyPressed()
                for _,window in ipairs(UIManager._window_stack) do assert(window.widg~=busy,'native key dismissal left loading window') end
            elseif change=='close' then plugin:closeWeReadUI()
            elseif change=='suspend' then plugin:onSuspend()
            elseif change=='session' then plugin._reader_session_gen=(plugin._reader_session_gen or 0)+1
            elseif change=='epoch' then plugin.discovery_epoch=(plugin.discovery_epoch or 0)+1
            elseif change=='cookie' then local copy={};for k,v in pairs(key) do copy[k]=v end;copy.wr_skey='mock-catalog-replacement';settings:set('cookies',copy)
            elseif change=='header' then settings:set('wr_ticket','mock-catalog-ticket-replacement')
            elseif change=='cache' then settings.cache_dir=root..'-changed'
            else local books=settings:get('books',{});books[sample.book_id].cache_dir=sample.cache_dir..'-moved';settings:set('books',books) end
        end)
        pump(function() return not plugin.mp_catalog_job end)
        settings:set('cookies',key);settings:set('wr_ticket',ticket);settings.cache_dir=root;settings:flush()
        local kept=settings:get('books',{})[sample.book_id]
        assert(#kept.mp_articles==1 and kept.mp_articles[1].reviewId==snapshot.reviewId and kept.mp_articles[1].title==snapshot.title
            and kept.mp_articles[1].createTime==snapshot.createTime and kept.mp_articles_time==123,'stale result replaced catalog: '..change)
        assert(not plugin._mp_article_list_view,'stale result reopened list: '..change)
    end
    -- A transient HTTP failure restores a saved directory without retry/renewal.
    book=setup('900096');control{match='/web/mp/articles',status=429,times=1,delay=0}
    gets=count('/web/mp/articles');plugin:fetchMPArticles(book);pump(function() return not plugin.mp_catalog_job end)
    assert(plugin._mp_article_list_view and count('/web/mp/articles')==gets+1 and #settings:get('books',{})[book.book_id].mp_articles==1,'429 cleared rows or retried')
    close_info();control{match='',times=0,delay=0}
    -- Storage errors show fixed guidance and leave the old catalog available.
    local cache=plugin.cacheMPArticles;plugin.cacheMPArticles=function() error('synthetic catalog storage failure') end
    plugin:fetchMPArticles(book);pump(function() return not plugin.mp_catalog_job end);plugin.cacheMPArticles=cache
    assert(not plugin.busy_message and plugin._mp_article_list_view and #settings:get('books',{})[book.book_id].mp_articles==1,'storage error lost cached directory or left busy UI')
    close_info();plugin:closeWeReadUI()
    assert(UIManager:getTopmostVisibleWidget()==plugin.ui,'catalog fixture did not return to reader')
    Model.read=read;client.request=request;plugin.openFile=open
    assert(count('/web/login/renewal')==renewal+1 and count('/web/book/read')==writes and require('weread.lib.cookie').to_header(settings:get('cookies'))==cookies,'catalog changed credentials/cloud reading data')
    local report={result='PASS',synthetic_only=true,first_page_only=true,ui_heartbeat=true,http_in_child=true,
        cached_body_opened_after_title_change=true,fresh_progress_intent_preserved=true,new_settings_instance_catalog_readback=true,
        offline_keeps_menu=true,malformed_missing_object_dates_and_oversize_preserve_cache=true,failed_refresh_restores_list=true,
        valid_empty_page_label_and_persistence=true,valid_empty_catalog_reopens_offline=true,empty_page_does_not_delete_files=true,large_pipe_100_rows_and_native_pagination=true,
        first_batch_label_visible=true,cancel_close_suspend_session_epoch_cookie_header_cache_move_guards=true,
        http_429_no_retry=true,storage_error_fallback=true,native_key_dismiss_closes_window=true,returns_to_visible_reader=true,credential_renewals=1,login_recovery_bounded_once=true,account_data_writes=0}
    local file=assert(io.open(home..'/../evidence/mp-catalog-background.json','wb'));file:write(client:json_encode(report));file:close()
    print('PASS: MP catalog -> responsive one-GET worker, large native list/first-batch label, empty/malformed/429/storage cases, persisted cache/state and cancellation/ownership; one confirmed login recovery, no account-data writes')
end

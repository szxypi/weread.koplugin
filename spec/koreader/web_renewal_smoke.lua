-- Isolated settings + actual HTTP/JSON/fork/fsync/widgets; no original reader auth changes.
return function(plugin,count,flush,home,pump)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local Settings=require('weread.lib.settings')
    local LuaSettings=require('luasettings')
    local Auth=require('weread.lib.web_authorization')
    local Renewal=require('weread.lib.web_renewal')
    local WebUI=require('weread.ui.web_renewal')
    local Content=require('weread.lib.content')
    local lfs=require('libs/libkoreader-lfs')
    local ffi=require('ffi')
    local socket=require('socket')
    local http,ltn12=require('socket.http'),require('ltn12')
    local root=plugin.settings.data_dir..'/web-renewal-fixture'
    assert(require('util').makePath(root))
    local data=plugin.client:json_decode(plugin.client:json_encode(plugin.settings.store.data))
    data.books={};data.account={user_vid='900000',name='Synthetic renewal',login_method='mock'};data.auth_epoch=1
    data.cookies={wr_vid='900000',wr_skey='mock-only'};data.wr_ticket='';data.wr_wrpa='';data.api_key='mock-api-key'
    data.cache.download_mp_images=false
    local settings=setmetatable({data_dir=root,cache_dir=root..'/cache',default_cache_dir=root..'/cache',
        settings_file=root..'/configuration.lua',mock_endpoint=plugin.settings.mock_endpoint},Settings)
    settings.store=LuaSettings:open(settings.settings_file);settings.store.data=data;settings:flush()
    local client=require('weread.lib.client'):new(settings)
    local host={settings=settings,client=client,ui=plugin.ui,discovery_epoch=0,_reader_session_gen=1,
        library_db=require('weread.lib.library_db'):new(settings),
        progress_sync=setmetatable({},{__index=function() return function() end end}),
        read_report=setmetatable({},{__index=function() return function() end end}),
        downloader={cancelPrefetch=function() end},qr_login={cancel=function() end}}
    -- Reuse installed methods, never another instance's private callback state.
    local methods={}
    for _,module in ipairs({'weread.ui.common','weread.ui.library','weread.lib.reader_lifecycle',
        'weread.ui.annotations_controller','weread.ui.xpointer_overlay_controller'}) do
        for key,value in pairs(require(module)) do if type(value)=='function' then methods[key]=value end end
    end
    setmetatable(host,{__index=methods})
    local opened;host.openFile=function(_self,path) opened=path end
    local parent=tonumber(ffi.C.getpid());local original_request=client.request
    client.request=function(self,options)
        assert(tonumber(ffi.C.getpid())~=parent,'credential/catalog/content HTTP blocked native UI')
        return original_request(self,options)
    end
    local function control(values)
        local body=client:json_encode(values)
        local _,code=http.request{url=settings.mock_endpoint..'/__control',proxy=settings.mock_endpoint,method='POST',
            headers={['content-type']='application/json',['content-length']=#body},source=ltn12.source.string(body),sink=ltn12.sink.null()}
        assert(code==200)
    end
    local function close_info()
        local top=UIManager:getTopmostVisibleWidget();if top and top~=plugin.ui and top.text then UIManager:close(top) end
    end
    local function raw(path) local file=assert(io.open(path,'rb'));local text=file:read('*a');file:close();return text end
    local function fresh(mode)
        host:closeWeReadUI();close_info()
        settings:update_auth({account={user_vid='900000',name='Synthetic renewal',login_method='mock'},
            cookies={wr_vid='900000',wr_skey='mock-only'},wr_ticket='',wr_wrpa=''}, {replace_cookies=true})
        control{match='',times=0,delay=0,web_renewal_mode=mode or 'plain'}
        host.web_renewal=Renewal:new{settings=settings,client=client,scheduler=UIManager}
    end
    local function manual()
        assert(host:renewCookieWithUI());return host.web_renewal
    end
    local function wait()
        pump(function() return not host._web_renewal_request and not host.mp_catalog_job and not host.mp_download_job end)
    end
    local before_writes=count('/web/book/read')
    fresh('rotate');local previous=Auth.capture(settings);local posts=count('/web/login/renewal');local heartbeat=false
    local model=Auth.run
    Auth.run=function(...) socket.sleep(.35);return model(...) end
    manual();UIManager:scheduleIn(.1,function() heartbeat=host._web_renewal_request~=nil;UIManager:forceRePaint();Screen:shot(home..'/../evidence/web-renewal-loading.png') end)
    wait();Auth.run=model
    local renewed=Auth.capture(settings)
    assert(heartbeat and posts+1==count('/web/login/renewal') and renewed.revision~=previous.revision
        and renewed.cookies.wr_skey=='XXXrenewed-native' and renewed.cookies.wr_rt=='XXXrefresh-native' and renewed.wr_ticket=='synthetic-renewed-ticket','renewal did not run/save verified headers in child')
    local record=assert(host.web_renewal.store:read())
    assert(record.phase=='done' and not record.candidate and not raw(host.web_renewal.store.path):find('XXXrenewed-native',1,true),'completed marker retained receipt credentials')
    -- Production Settings methods on a fresh primary reader, without the mock
    -- constructor's deliberate auth reset; no ordinary user profile is loaded.
    local reopened=setmetatable({store=LuaSettings:open(settings.settings_file),settings_file=settings.settings_file,data_dir=root},Settings)
    assert(Auth.capture(reopened).revision==renewed.revision,'fresh primary settings readback differs')
    close_info()
    -- Omitted receipt headers retain the prior same-owner grant.
    control{web_renewal_mode='plain'};manual();wait()
    assert(Auth.capture(settings).wr_ticket==renewed.wr_ticket and settings:get('wr_wrpa')==renewed.wr_wrpa,'missing headers erased existing authorization')
    close_info()
    -- Save failure retains a receipt and asks for a local retry, without POST.
    fresh('rotate');local service=WebUI.service(host);local sync=service.store.sync;local fail=true
    service.store.sync=function(path) if path==settings.settings_file and fail then return false end;return sync(path) end
    posts=count('/web/login/renewal');manual()
    pump(function() return host._web_renewal_request and host._web_renewal_request.dialog end)
    local dialog=host._web_renewal_request.dialog
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/web-renewal-save-retry.png')
    fail=false;dialog.ok_callback();wait();service.store.sync=sync
    assert(count('/web/login/renewal')==posts+1 and service.store:read().phase=='done' and Auth.capture(settings).cookies.wr_skey=='XXXrenewed-native','save-only retry repeated POST or failed recovery')
    close_info()
    -- A received but unverified credential survives a new coordinator instance.
    fresh('verify-fail');posts=count('/web/login/renewal');manual();wait()
    assert(host.web_renewal.store:read().phase=='candidate' and settings:get('cookies').wr_skey=='mock-only','unverified receipt was lost or published')
    close_info();control{web_renewal_mode='plain'};host.web_renewal=Renewal:new{settings=settings,client=client,scheduler=UIManager}
    manual();wait()
    assert(count('/web/login/renewal')==posts+1 and host.web_renewal.store:read().phase=='done','receipt reopen replayed renewal instead of verification reads')
    close_info()
    -- Lost/rejected/foreign receipts never change current auth or auto-replay.
    for _,mode in ipairs({'reject','empty','foreign'}) do
        fresh(mode);previous=Auth.capture(settings);posts=count('/web/login/renewal');manual();wait();close_info()
        assert(Auth.capture(settings).revision==previous.revision and host.web_renewal.store:read().phase=='pending','invalid receipt replaced current login: '..mode)
        host.web_renewal=Renewal:new{settings=settings,client=client,scheduler=UIManager};manual();wait();close_info()
        assert(count('/web/login/renewal')==posts+1,'reopen repeated unconfirmed POST: '..mode)
    end
    -- Cancel only after the server has observed the POST; its unknown outcome
    -- remains durable. Real key dismissal removes the native loading window.
    fresh('rotate');control{match='/api/userInfo',times=0,delay=.6};posts=count('/web/login/renewal');manual()
    pump(function() return count('/web/login/renewal')==posts+1 end)
    local busy=assert(host.busy_message);busy:onAnyKeyPressed();wait()
    assert(not host.busy_message and host.web_renewal.store:read().phase=='pending','cancel lost durable unknown intent')
    host.web_renewal=Renewal:new{settings=settings,client=client,scheduler=UIManager};manual();wait();close_info()
    assert(count('/web/login/renewal')==posts+1,'cancel/reopen repeated a possibly consumed request')
    -- Real lifecycle cancellation and changed scope/document bindings reject old work.
    for _,change in ipairs({'suspend','close','document_close','account','session','document'}) do
        fresh('rotate');control{match='/api/userInfo',times=0,delay=.4};previous=Auth.capture(settings)
        local ui=host.ui;manual()
        UIManager:scheduleIn(.1,function()
            if change=='suspend' then host:onSuspend()
            elseif change=='close' then host:closeWeReadUI()
            elseif change=='document_close' then host.ui={document={file='closing-fixture-document'}};host:onCloseDocument()
            elseif change=='account' then settings:update_auth({account={user_vid='900099'},cookies={wr_vid='900099',wr_skey='mock-other'}},{replace_cookies=true});host:onWeReadAccountChanged()
            elseif change=='session' then host._reader_session_gen=host._reader_session_gen+1
            else host.ui={document={file='other-document'}} end
        end)
        wait();host.ui=ui
        if change=='account' then assert(settings:get('account').user_vid=='900099','old receipt overwrote changed account')
        else assert(Auth.capture(settings).revision==previous.revision,'stale renewal overwrote current login: '..change) end
        assert(not host.busy_message,'stale renewal kept loading')
    end
    -- Login failure recovers exactly once, retaining concurrently updated data.
    fresh('rotate')
    local book={book_id='MP_WXS_900096',title='合成续期公众号',cache_dir=root..'/mp-cache',progress=.3,pending_upload_position={offset=7}}
    local article={reviewId='cache-fixture-a/b',title='已保存正文'};book.mp_articles={article}
    local path=Content.save_mp_article_html(settings,book,article,'<p>既有正文</p>')
    local books=settings:get('books',{});books[book.book_id]=book;settings:set('books',books);settings:flush()
    control{match='/web/mp/articles',times=1,status=401,delay=0};posts=count('/web/login/renewal');local reads=count('/web/mp/articles')
    host:fetchMPArticles(book);pump(function() return host._web_renewal_request~=nil end)
    books=settings:get('books',{});books[book.book_id].progress=.8;books[book.book_id].pending_upload_position.offset=19
    settings:set('books',books);settings:set('web_fixture_preference','updated during HTTP');settings:flush();wait()
    assert(count('/web/mp/articles')==reads+2 and count('/web/login/renewal')==posts+1 and host._mp_article_list_view,'catalog did not recover once')
    local saved=settings:get('books',{})[book.book_id]
    assert(saved.progress==.8 and saved.pending_upload_position.offset==19 and settings:get('web_fixture_preference')=='updated during HTTP','credential commit overwrote fresh local state')
    host._mp_article_list_view:onMenuSelect(host._mp_article_list_view.item_table[1]);assert(opened==path,'renewed catalog lost cached identity path')
    control{match='/web/mp/articles',times=-1,status=401,delay=0};posts=count('/web/login/renewal');reads=count('/web/mp/articles')
    host:fetchMPArticles(book);wait();close_info()
    assert(count('/web/mp/articles')==reads+2 and count('/web/login/renewal')==posts+1,'persistent catalog login failure looped renewal')
    -- Body recovery uses a fresh stage; a second login failure preserves old HTML.
    fresh('rotate');control{match='/web/mp/content',times=1,status=401,delay=0};posts=count('/web/login/renewal');reads=count('/web/mp/content');opened=nil
    host:downloadMPArticleAndRead(book,article);wait()
    assert(opened==path and raw(path):find('合成公众号正文甲',1,true) and count('/web/login/renewal')==posts+1 and count('/web/mp/content')==reads+2,'article login recovery did not use fresh credentials/stage')
    local body=raw(path)
    fresh('rotate');control{match='/web/mp/content',times=1,status=401,delay=0};posts=count('/web/login/renewal');reads=count('/web/mp/content');opened=nil
    host:downloadMPArticleAndRead(book,article);pump(function() return host._web_renewal_request~=nil end)
    local replacement=assert(io.open(path..'.external','wb'));replacement:write(body..'<!-- external replacement -->');replacement:close();assert(os.rename(path..'.external',path))
    body=raw(path);wait()
    assert(not opened and raw(path)==body and count('/web/mp/content')==reads+1 and count('/web/login/renewal')==posts+1,'renewal re-read/replaced a concurrently changed cache')
    fresh('rotate');control{match='/web/mp/content',times=-1,status=401,delay=0};posts=count('/web/login/renewal');reads=count('/web/mp/content');opened=nil
    host:downloadMPArticleAndRead(book,article);wait();close_info()
    assert(not opened and raw(path)==body and count('/web/login/renewal')==posts+1 and count('/web/mp/content')<=reads+4,'persistent body login failure looped or replaced old cache')
    control{match='/web/mp/content',times=1,status=429,delay=0};posts=count('/web/login/renewal');reads=count('/web/mp/content')
    host:downloadMPArticleAndRead(book,article);wait();close_info()
    assert(count('/web/mp/content')==reads+1 and count('/web/login/renewal')==posts and raw(path)==body,'429 repeated a body read/renewal')
    -- A corrupt marker is fail-closed; explicit account clearing can remove it
    -- only after the old login epoch is invalidated, retaining downloaded files.
    fresh('plain');local before=Auth.capture(settings);posts=count('/web/login/renewal')
    local broken=assert(io.open(host.web_renewal.store.path,'wb'));broken:write('broken');broken:close()
    manual();wait();close_info();assert(count('/web/login/renewal')==posts and Auth.capture(settings).revision==before.revision,'corrupt state dispatched renewal')
    assert(not WebUI.clear_for_logout(host),'active login was allowed to forget an unknown receipt')
    host:confirmClearAccount();local clear=UIManager:getTopmostVisibleWidget();clear.ok_callback();UIManager:close(clear);close_info()
    assert(not settings:get_auth_scope() and not lfs.symlinkattributes(host.web_renewal.store.path) and raw(path)==body,'explicit logout lost caches or retained corrupt marker')
    fresh('plain');manual();wait();close_info();assert(host.web_renewal.store:read().phase=='done','fresh login could not renew after clearing damaged state')
    fresh('plain');host:closeWeReadUI();close_info()
    assert(UIManager:getTopmostVisibleWidget()==plugin.ui and count('/web/book/read')==before_writes,'renewal left an overlay or wrote reading data')
    assert(lfs.attributes(root,'mode')=='directory')
    local report={result='PASS',synthetic_only=true,actual_child_http=true,ui_heartbeat=true,primary_settings_readback=true,
        rotated_cookies_headers_saved=true,omitted_headers_retained=true,completed_receipt_removed=true,save_retry_without_post=true,
        unverified_receipt_survives_coordinator_reopen=true,verification_only_resume=true,rejected_empty_foreign_no_publish_or_replay=true,
        native_key_cancel_after_dispatch_no_replay=true,lifecycle_account_session_document_guards=true,
        catalog_401_once_recovery=true,persistent_catalog_401_bounded=true,article_401_new_stage_recovery=true,
        persistent_article_401_preserves_body=true,cache_replacement_during_renewal_preserved=true,corrupt_state_blocks_dispatch=true,explicit_logout_repairs_state_without_deleting_cache=true,http_429_no_retry_or_renewal=true,fresh_local_state_preserved=true,
        returns_to_reader=true,account_data_writes=0,credentials_are_synthetic=true}
    local file=assert(io.open(home..'/../evidence/web-renewal.json','wb'));file:write(client:json_encode(report));file:close()
    print('PASS: Web renewal -> real child HTTP, durable intent/receipt, fsync/readback, native save retry, cancellation/no-replay, account guards and catalog/body login recovery once')
end

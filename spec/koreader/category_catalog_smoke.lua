-- Packaged native menus, actual HTTP/worker/SQLite; synthetic public data.
return function(plugin,evidence)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local Catalog=require('weread.lib.category_catalog')
    local Settings=require('weread.lib.settings')
    local socket,ffi=require('socket'),require('ffi')
    local pid=tonumber(ffi.C.getpid())
    local client,settings=plugin.client,plugin.settings
    local http,ltn12=require('socket.http'),require('ltn12')
    local function request(path,data)
        local body=data and client:json_encode(data);local chunks={}
        local _,code=http.request{url=settings.mock_endpoint..path,proxy=settings.mock_endpoint,method=data and 'POST' or 'GET',
            source=body and ltn12.source.string(body),sink=ltn12.sink.table(chunks),
            headers=body and {['content-type']='application/json',['content-length']=#body} or {}}
        assert(code==200);return client:json_decode(table.concat(chunks))
    end
    local function count()
        local n=0;for _,row in ipairs(request('/__state').requests) do if row.path=='/web/categories' then n=n+1 end end;return n
    end
    local function control(value) request('/__control',value) end
    local function pump(predicate)
        local deadline=socket.gettime()+20
        repeat
            UIManager:shiftScheduledTasksBy(-1e9);UIManager:setInputTimeout(0);UIManager:handleInput()
            if predicate() then return end
            assert(socket.gettime()<deadline,'category runtime deadline')
            socket.sleep(0.01)
        until false
    end
    local function close_notice()
        local widget=UIManager:getTopmostVisibleWidget()
        if widget and widget~=plugin._discovery_menu and widget~=plugin.shelf_view then UIManager:close(widget) end
    end
    plugin:closeWeReadUI()
    local native_request=client.request
    client.request=function(self,options)
        if options.url=='https://weread.qq.com/web/categories?rank=1&synckey=0' then
            assert(tonumber(ffi.C.getpid())~=pid,'category HTTP ran on UI event loop')
            assert(options.method=='GET' and options.skip_cookie==true and options.persist_response_cookies==false
                and not options.body and not options.headers.Authorization and not options.headers.Cookie,'public request attached credentials')
        end
        return native_request(self,options)
    end
    control{match='/web/categories',times=0,delay=0.45}
    local before=count()
    assert(plugin:showDiscoveryCategories(true))
    pump(function() return plugin.category_catalog_worker and plugin.category_catalog_worker.job~=nil end)
    assert(plugin.category_catalog_worker.job.pid~=pid,'category worker is not independent')
    local heartbeat=false;UIManager:scheduleIn(0.1,function() heartbeat=true end)
    pump(function() return heartbeat end)
    assert(plugin.category_catalog_request,'category HTTP blocked heartbeat')
    pump(function() return not plugin.category_catalog_request end)
    assert(count()==before+1 and plugin._discovery_menu and not plugin.busy_message,'category result missing or repeated HTTP')
    UIManager:forceRePaint();Screen:shot(evidence..'/category-catalog-loaded.png')
    local saved=assert(Catalog:new(Settings:new(),client):read(),'new cache instance could not reopen SQLite')
    assert(saved.ranks[1].id=='rising' and saved.categories[1].children[1].id=='100001','stored hierarchy lost child/rank identity')
    -- This database contains only public labels, so signed-out browsing can use
    -- it too. No personal library/account database is opened for this cache.
    plugin:closeWeReadUI();plugin.discovery_categories=nil
    local account=settings:get('account');settings:set('account',{});settings:flush()
    plugin.isNetworkOnline=function() return false end
    plugin.category_catalog_store=Catalog:new(Settings:new(),client)
    assert(plugin:showDiscoveryCategories() and plugin._discovery_menu and count()==before+1,'guest offline reopen fetched HTTP or lost cache')
    local stale=plugin._discovery_menu
    settings:set('account',account);settings:flush()
    stale.item_table[3].callback()
    assert(not plugin.category_catalog_request and count()==before+1,'old guest menu refreshed after account switch')
    plugin:closeWeReadUI();plugin.discovery_categories=nil
    saved.loaded_at=os.time()-3600;assert(plugin.category_catalog_store:write(saved))
    assert(plugin:showDiscoveryCategories())
    assert(plugin._discovery_menu.title:find(require('weread.lib.plugin_util').tr('Cached'),1,true),'stale saved hierarchy not marked cached')
    local old_picker=plugin._discovery_menu
    assert(plugin:showDiscoveryCategories())
    local replacement=assert(plugin._discovery_menu);assert(replacement~=old_picker)
    replacement:onMenuSelect(replacement.item_table[3])
    assert(plugin._discovery_menu and plugin._discovery_menu~=replacement,'replacement picker retained an expired epoch')
    close_notice()
    UIManager:forceRePaint();Screen:shot(evidence..'/category-catalog-offline.png')
    assert(not plugin:showDiscoveryCategories(true) and not plugin.category_catalog_request,'offline refresh launched worker')
    close_notice();plugin.discovery_categories.loaded_at=os.time()+3600
    assert(plugin:showDiscoveryCategories() and plugin._discovery_menu.title:find(require('weread.lib.plugin_util').tr('Cached'),1,true),
        'clock rollback discarded public labels or marked them fresh')
    close_notice();plugin.isNetworkOnline=function() return true end
    plugin:closeWeReadUI()
    control{match='/web/categories',times=1,status=429,delay=0}
    assert(plugin:showDiscoveryCategories(true));pump(function() return not plugin.category_catalog_request end)
    assert(plugin._discovery_menu and plugin.category_catalog_store:read().loaded_at==saved.loaded_at,'429 replaced persisted hierarchy or lost picker')
    close_notice();local after_failure=count()
    assert(after_failure==before+2,'category 429 retried automatically')

    -- Native busy dismiss, view close, sleep and account changes terminate the
    -- active process; late callbacks do not write caches or reopen menus.
    control{match='/web/categories',times=0,delay=0.6}
    for _,change in ipairs({'dismiss','view','suspend','account'}) do
        plugin:closeWeReadUI();assert(plugin:showDiscoveryCategories(true))
        pump(function() return plugin.category_catalog_worker.job~=nil end)
        if change=='dismiss' then plugin.busy_message:onTapClose()
        elseif change=='view' then plugin:closeWeReadUI()
        elseif change=='suspend' then plugin:onSuspend();plugin:onResume()
        else settings:set('account',{user_vid='90009999'});settings:flush();plugin:onWeReadAccountChanged() end
        assert(not plugin.category_catalog_request and not plugin.category_catalog_worker.job and not plugin.busy_message,'lifecycle retained category worker')
        assert(not plugin._discovery_menu,'lifecycle reopened category picker')
        assert(plugin.category_catalog_store:read().loaded_at==saved.loaded_at,'cancel replaced saved hierarchy')
        if change=='account' then settings:set('account',account);settings:flush();plugin:onWeReadAccountChanged() end
    end
    control{match='',times=0,delay=0}
    local until_time=socket.gettime()+0.7;pump(function() return socket.gettime()>until_time end)
    assert(not plugin._discovery_menu,'late result reopened picker')

    -- Corrupt/oversized persisted rows fail closed. The test modifies only its
    -- isolated public cache, then restores the known synthetic hierarchy.
    local SQ3=require('lua-ljsqlite3/init')
    local function seed(payload,stamp)
        local db=SQ3.open(settings.data_dir..'/bookstore-public.db')
        local stmt=db:prepare('UPDATE category_catalog SET payload=?,updated_at=? WHERE id=1')
        stmt:bind(payload,stamp):step();stmt:close();db:close()
    end
    seed('broken',saved.loaded_at);assert(not plugin.category_catalog_store:read(),'corrupt persisted JSON accepted')
    seed(string.rep('文',Catalog.MAX_PAYLOAD),saved.loaded_at);assert(not plugin.category_catalog_store:read(),'oversized UTF-8 cache accepted')
    assert(plugin.category_catalog_store:write(saved))
    local write=plugin.category_catalog_store.write
    plugin.category_catalog_store.write=function() return false end
    assert(plugin:showDiscoveryCategories(true));pump(function() return not plugin.category_catalog_request end)
    assert(plugin._discovery_menu and plugin.category_catalog_store:read().loaded_at==saved.loaded_at,'cache failure discarded new menu or replaced old cache')
    close_notice();plugin.category_catalog_store.write=write
    client.request=native_request;plugin:closeWeReadUI()
    local report={result='PASS',synthetic_only=true,public_get_in_child=true,ui_heartbeat=true,sqlite_reopened=true,
        guest_offline_reopen=true,rank_and_subcategory_preserved=true,stale_menu_rejected=true,cached_age_label=true,
        replacement_menu_callbacks_current=true,
        clock_rollback_kept_cached_labels=true,
        rate_limit_not_retried=true,failed_refresh_kept_cache=true,cache_failure_kept_current_menu=true,
        dismiss_close_suspend_account_cancelled=true,late_results_discarded=true,corrupt_and_oversized_cache_rejected=true,
        credentials_attached=false,account_data_writes=0}
    local fd=assert(io.open(evidence..'/category-catalog.json','w'));fd:write(client:json_encode(report));fd:close()
    print('PASS: public category HTTP in child, native menu heartbeat, guest SQLite/offline reopen, stale callbacks, 429, cancellation, corruption and save failure')
end

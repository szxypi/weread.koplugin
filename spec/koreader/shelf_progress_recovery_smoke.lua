-- Actual worker files, HTTP, durable Web renewal, SQLite and native redraws.
return function(plugin,flush,evidence)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local ffi=require('ffi')
    local socket=require('socket')
    local http,ltn12=require('socket.http'),require('ltn12')
    local Settings=require('weread.lib.settings')
    local LuaSettings=require('luasettings')
    local Client=require('weread.lib.client')
    local Auth=require('weread.lib.web_authorization')
    plugin:closeWeReadUI()
    local root=plugin.settings.data_dir..'/shelf-progress-renewal';assert(require('util').makePath(root..'/cache'))
    local data=plugin.client:json_decode(plugin.client:json_encode(plugin.settings.store.data))
    data.books={};data.api_key='';data.cookies={wr_vid='900000',wr_skey='synthetic-progress-old'}
    data.account={user_vid='900000',name='合成进度恢复',login_method='mock'};data.auth_epoch=1
    data.wr_ticket,data.wr_wrpa='','';data.shelf={view_mode='list',paginated=true,sort_order='default'}
    local settings=setmetatable({data_dir=root,cache_dir=root..'/cache',default_cache_dir=root..'/cache',
        settings_file=root..'/configuration.lua',mock_endpoint=plugin.settings.mock_endpoint},Settings)
    settings.store=LuaSettings:open(settings.settings_file);settings.store.data=data;settings:flush()
    local factory=Settings.new;Settings.new=function() return settings end
    local class=getmetatable(plugin);local created,host=pcall(class.new,class,{ui=plugin.ui});Settings.new=factory
    assert(created and host,'isolated progress host initialization failed')
    host.isNetworkOnline,host.isNetworkConnected=function() return true end,function() return true end
    host.fetchVisibleShelfCovers=function() end
    local client=host.client;local endpoint=settings.mock_endpoint
    local books,archives=plugin.library_db:getShelf(),plugin.library_db:getShelfArchives()
    assert(host.library_db:cacheShelf(books,archives) and #books>=3)
    local selected={books[1],books[2],books[3]};local id=selected[1].bookId
    settings:set('books',{[id]={book_id=id,title=selected[1].title,progress=83,chapter_uid=99,
        pending_upload_account=host.library_db:accountKey(),pending_upload_position={book_id=id,percent=83,chapter_uid=99}}});settings:flush()
    local parent=tonumber(ffi.C.getpid());local request=Client.request
    client.request=function(self,options)
        assert(tonumber(ffi.C.getpid())~=parent,'display/renewal HTTP ran on UI process')
        return request(self,options)
    end
    local function control(values)
        local raw=client:json_encode(values)
        local _,code=http.request{url=endpoint..'/__control',proxy=endpoint,method='POST',
            headers={['content-type']='application/json',['content-length']=#raw},source=ltn12.source.string(raw),sink=ltn12.sink.null()}
        assert(code==200)
    end
    local function count(path)
        local chunks={};local _,code=http.request{url=endpoint..'/__state',proxy=endpoint,sink=ltn12.sink.table(chunks)};assert(code==200)
        local total=0;for _,value in ipairs(client:json_decode(table.concat(chunks)).totals) do if value.path==path then total=total+value.count end end
        return total
    end
    local function pump(predicate)
        local deadline=socket.gettime()+30
        while not predicate() do assert(socket.gettime()<deadline,'progress recovery deadline');flush();socket.sleep(.01) end
    end
    local function wait()
        pump(function() return not host.shelf_progress_worker:busy() and not host._web_renewal_request
            and not (host.shelf_progress_context and host.shelf_progress_context.renewing) end)
    end
    local function fresh()
        host:closeWeReadUI()
        settings:update_auth({cookies={wr_vid='900000',wr_skey='synthetic-progress-old'},wr_ticket='',wr_wrpa=''}, {replace_cookies=true})
        host.shelf_progress_retry_at,host.shelf_progress_retry_revision=nil,nil
        control{match='',times=0,delay=0,web_renewal_mode='rotate'}
        local values={};for _,book in ipairs(books) do values[#values+1]={book_id=book.bookId,percent=9,fetched_at=os.time()} end
        assert(host.library_db:putShelfProgress(values));host:applyShelfSnapshot(books,archives);host:showShelfView('books')
    end
    local function start()
        host:refreshVisibleShelfProgress(host.shelf_view,selected,host:prepareShelfProgress(selected),
            {force=true,on_redraw=function() host:showShelfView('books') end})
    end
    local function percent(book_id) return host.library_db:getShelfProgress({book_id})[book_id].percent end
    local read=client.get_shelf_display_progress;local prefix=true
    client.get_shelf_display_progress=function(self,book_id,access)
        local value=read(self,book_id,access)
        if prefix and book_id==id and access.cookies.wr_skey=='synthetic-progress-old' then
            control{match='/web/book/getProgress',times=1,status=401}
        end
        return value
    end
    local writes=count('/web/book/read');fresh()
    local posts,gets=count('/web/login/renewal'),count('/web/book/getProgress')
    local run=Auth.run;Auth.run=function(...) socket.sleep(.35);return run(...) end
    start();local heartbeat=false
    UIManager:scheduleIn(.1,function() heartbeat=host.shelf_progress_context~=nil end)
    wait();Auth.run=run;prefix=false
    assert(heartbeat and count('/web/book/getProgress')==gets+4 and count('/web/login/renewal')==posts+1,'prefix/suffix recovery request budget wrong')
    assert(percent(id)==37 and percent(selected[2].bookId)==0 and percent(selected[3].bookId)==0,'resumed suffix not saved')
    assert(settings:get('cookies').wr_skey=='XXXrenewed-native' and host.web_renewal.store:read().phase=='done','renewed login was not committed')
    assert(host.shelf_view.books[1]._shelf_progress==83 and host.shelf_view.books[1]._shelf_progress_local,'native redraw replaced pending local progress')
    UIManager:forceRePaint();Screen:shot(evidence..'/shelf-progress-renewed.png')
    -- Persistent 401 is bounded to one maintenance and two progress reads.
    fresh();control{match='/web/book/getProgress',times=-1,status=401}
    posts,gets=count('/web/login/renewal'),count('/web/book/getProgress');start();wait()
    assert(count('/web/login/renewal')==posts+1 and count('/web/book/getProgress')==gets+2 and percent(id)==9,'persistent 401 replayed renewal or lost cache')
    start();wait();assert(count('/web/book/getProgress')==gets+2,'failed renewed read ignored wait')
    -- 429 never initiates authentication maintenance.
    fresh();control{match='/web/book/getProgress',times=-1,status=429}
    posts,gets=count('/web/login/renewal'),count('/web/book/getProgress');start();wait()
    assert(count('/web/login/renewal')==posts and count('/web/book/getProgress')==gets+1 and percent(id)==9,'429 renewed login or replaced cache')
    -- Suspend owns cancellation; an unknown intent is not replayed later.
    fresh();control{match='/web/book/getProgress',times=1,status=401}
    Auth.run=function(...) socket.sleep(.8);return run(...) end
    posts=count('/web/login/renewal');start();pump(function() return host._web_renewal_request~=nil end)
    local worker=host.web_renewal.worker;local pid=assert(worker.job.pid)
    host:onSuspend();pump(function() return worker.runner.done(pid) end);Auth.run=run
    assert(not host.shelf_progress_context and not host._web_renewal_request and host.web_renewal.store:read().phase=='pending','suspend lost cancellation or unknown intent')
    control{match='/web/book/getProgress',times=1,status=401};start();wait()
    assert(count('/web/login/renewal')==posts,'suspend/reopen replayed an unconfirmed intent')
    local saved=settings:get('books')[id]
    assert(saved.progress==83 and saved.chapter_uid==99 and saved.pending_upload_position.percent==83,'progress reading changed local sync intent')
    assert(count('/web/book/read')==writes,'display recovery wrote reading data')
    host:closeWeReadUI();control{match='',times=0,delay=0,web_renewal_mode='plain'}
    local file=assert(io.open(evidence..'/shelf-progress-recovery.json','wb'))
    file:write(client:json_encode({result='PASS',synthetic_only=true,real_background_http=true,durable_web_renewal=true,
        ui_heartbeat=true,valid_prefix_kept=true,only_suffix_resumed=true,renewed_cookies_readback=true,native_local_pending_priority=true,
        persistent_401_once_only=true,failed_read_wait=true,http_429_no_renewal=true,suspend_worker_reaped=true,
        unknown_intent_not_replayed=true,local_sync_state_preserved=true,account_data_writes=0}));file:close()
    print('PASS: visible progress -> actual child HTTP 401, durable renewal, prefix/suffix continuation, native pending priority, persistent/429 wait and suspend/no-replay')
end

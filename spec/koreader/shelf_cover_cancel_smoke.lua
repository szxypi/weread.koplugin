-- Real native cover children, delayed local HTTP, cancellation and reopening.
return function(plugin,flush,evidence)
    local UIManager=require('ui/uimanager')
    local util=require('ffi/util')
    local socket,http,ltn12=require('socket'),require('socket.http'),require('ltn12')
    local Settings=require('weread.lib.settings');local LuaSettings=require('luasettings')
    plugin:closeWeReadUI()
    -- Actual KOReader has its file manager/reader underneath the plugin. Keep
    -- that underlying window here so closing the test view does not quit SDL.
    local anchor=require('ui/widget/infomessage'):new{text='合成封面取消验证',dismissable=false}
    UIManager:show(anchor)
    local root=plugin.settings.data_dir..'/cover-cancellation';assert(require('util').makePath(root..'/cache'))
    local data=plugin.client:json_decode(plugin.client:json_encode(plugin.settings.store.data))
    data.books={};data.shelf={view_mode='cover',paginated=true,sort_order='default'}
    local settings=setmetatable({data_dir=root,cache_dir=root..'/cache',default_cache_dir=root..'/cache',
        settings_file=root..'/configuration.lua',mock_endpoint=plugin.settings.mock_endpoint},Settings)
    settings.store=LuaSettings:open(settings.settings_file);settings.store.data=data;settings:flush()
    local factory=Settings.new;Settings.new=function() return settings end
    local class=getmetatable(plugin);local created,host=pcall(class.new,class,{ui=plugin.ui});Settings.new=factory
    assert(created and host,'isolated cover host initialization failed')
    host.isNetworkOnline=function() return true end
    host.prepareShelfProgress=function() end;host.refreshVisibleShelfProgress=function() end
    local client,endpoint=host.client,settings.mock_endpoint
    local function state()
        local chunks={};local _,code=http.request{url=endpoint..'/__state',proxy=endpoint,sink=ltn12.sink.table(chunks)}
        assert(code==200);return client:json_decode(table.concat(chunks))
    end
    local function control(delay)
        local raw=client:json_encode{match='/mock/cover.png',delay=delay,times=0}
        local _,code=http.request{url=endpoint..'/__control',proxy=endpoint,method='POST',
            headers={['content-type']='application/json',['content-length']=#raw},source=ltn12.source.string(raw),sink=ltn12.sink.null()}
        assert(code==200)
    end
    local function pump(predicate,seconds)
        local deadline=socket.gettime()+(seconds or 15)
        while not predicate() do assert(socket.gettime()<deadline,'cover cancellation deadline');flush();socket.sleep(.01) end
    end
    local terminated,reaped,closed,owners,started={}, {}, {}, {}, {}
    host.shelf_cover_subprocess={
        run=function(task)
            local pid,fd=util.runInSubProcess(task,true)
            if pid then started[pid]=true end
            if fd then owners[fd]=pid end
            return pid,fd
        end,
        write_all=function(fd,value) return util.writeToFD(fd,value,true) end,
        is_done=function(pid) local done=util.isSubProcessDone(pid);if done then reaped[pid]=true end;return done end,
        terminate=function(pid) terminated[pid]=(terminated[pid] or 0)+1;return util.terminateSubProcess(pid) end,
        read_all=function(fd)
            local pid=assert(owners[fd]);owners[fd]=nil
            closed[pid]=(closed[pid] or 0)+1;return util.readAllFromFD(fd)
        end,
    }
    local report={result='UNVERIFIED',phase='init',synthetic_only=true,cases={},account_data_writes=0,authentication_posts=0}
    local sequence=0
    local function book(label,item)
        sequence=sequence+1
        return {bookId=tostring(990000+sequence),title='合成封面 '..label,author='测试作者',
            cover='https://weread.qq.com/mock/cover.png?case=cancel-'..label..'&item='..item}
    end
    local function begin(label)
        report.phase='begin_'..label
        host:closeWeReadUI();pump(function() return not host.shelf_cover_job end)
        local first,tail=book(label,1),book(label,2)
        control(5);host:applyShelfSnapshot({first,tail},{})
        local heartbeat=false;UIManager:scheduleIn(.1,function() heartbeat=true end)
        host:showShelfView('books')
        local job=assert(host.shelf_cover_job)
        pump(function() return (state().active_requests[first.cover] or 0)==1 and heartbeat end)
        assert(not reaped[job.pid] and not util.isSubProcessDone(job.pid),'cover child was not live before cancellation')
        return job,first,tail
    end
    local initial=state().totals
    local ok,failure=pcall(function()
        local job,first,tail=begin('close')
        report.phase='close_reopen'
        host:closeWeReadUI()
        assert(job.cancelled,'closing the native view did not cancel its live cover child')
        host:closeWeReadUI();control(0)
        local next_book=book('reopen',1);host:applyShelfSnapshot({next_book},{})
        host:showShelfView('books')
        assert(host.shelf_cover_job==job and host.shelf_cover_pending,'reopening bypassed the unreaped child')
        pump(function() return not host.shelf_cover_job end)
        assert(terminated[job.pid]>=1 and reaped[job.pid] and closed[job.pid]==1)
        assert(not host:getShelfCoverCache():pathFor(first) and not host:getShelfCoverCache():pathFor(tail))
        assert(host:getShelfCoverCache():pathFor(next_book) and host.shelf_view._item_rows[1]._has_cover)
        UIManager:forceRePaint();require('device').screen:shot(evidence..'/shelf-cover-reopened.png')
        report.cases.close_then_reopen=true

        job,first,tail=begin('account')
        report.phase='account'
        host:onWeReadAccountChanged();assert(job.cancelled and not host.shelf_cover_pending)
        pump(function() return not host.shelf_cover_job end,2)
        assert(terminated[job.pid]>=1 and reaped[job.pid] and closed[job.pid]==1 and not host.shelf_view)
        assert(not host:getShelfCoverCache():pathFor(first) and not host:getShelfCoverCache():pathFor(tail))
        report.cases.account_change=true

        job,first,tail=begin('list');report.phase='list'
        local layout=settings:get('shelf');layout.view_mode='list';settings:set('shelf',layout)
        host:showShelfView('books',nil,host.shelf_view)
        assert(job.cancelled and not host.shelf_view.cover_mode)
        pump(function() return not host.shelf_cover_job end,2)
        assert(terminated[job.pid]>=1 and reaped[job.pid] and closed[job.pid]==1)
        assert(not host:getShelfCoverCache():pathFor(first) and not host:getShelfCoverCache():pathFor(tail))
        layout.view_mode='cover';settings:set('shelf',layout);report.cases.switch_to_list=true

        job,first,tail=begin('portal');report.phase='portal'
        host:showDiscoveryPage('store',{}, {title='合成书城'})
        assert(job.cancelled and host.shelf_view.portal)
        pump(function() return not host.shelf_cover_job end,2)
        assert(terminated[job.pid]>=1 and reaped[job.pid] and closed[job.pid]==1)
        assert(not host:getShelfCoverCache():pathFor(first) and not host:getShelfCoverCache():pathFor(tail))
        report.cases.switch_to_portal=true

        job,first,tail=begin('suspend')
        report.phase='resume'
        host:onSuspend();assert(job.cancelled and host.shelf_cover_resume)
        control(0);host:onResume()
        pump(function() return not host.shelf_cover_job end)
        assert(terminated[job.pid]>=1 and reaped[job.pid] and closed[job.pid]==1)
        assert(host:getShelfCoverCache():pathFor(first) and host:getShelfCoverCache():pathFor(tail))
        assert(not host.shelf_cover_resume and host.shelf_view._item_rows[1]._has_cover)
        report.cases.suspend_then_resume=true

        job,first,tail=begin('suspend-close')
        report.phase='suspend_close'
        host:onSuspend();host:closeWeReadUI();control(0);host:onResume()
        pump(function() return not host.shelf_cover_job end,2)
        assert(terminated[job.pid]>=1 and reaped[job.pid] and closed[job.pid]==1)
        assert(not host.shelf_cover_resume and not host.shelf_cover_pending and not host.shelf_view)
        assert(not host:getShelfCoverCache():pathFor(first) and not host:getShelfCoverCache():pathFor(tail))
        report.cases.closed_during_suspend=true
        report.started_children,report.terminated_children,report.reaped_children,report.drained_pipes=0,0,0,0
        for pid in pairs(started) do
            assert(reaped[pid] and closed[pid]==1,'cover child or pipe ownership was not released once')
            report.started_children=report.started_children+1
            report.reaped_children=report.reaped_children+1
            report.drained_pipes=report.drained_pipes+1
            if terminated[pid] then report.terminated_children=report.terminated_children+1 end
        end
        assert(report.started_children==9 and report.terminated_children==6)
        report.result='PASS';report.phase='complete'
    end)
    control(0);host:closeWeReadUI()
    if host.shelf_cover_job then
        local job=host.shelf_cover_job;util.terminateSubProcess(job.pid);util.isSubProcessDone(job.pid,true)
        if job.read_fd then util.readAllFromFD(job.read_fd) end
        host.shelf_cover_job=nil
    end
    UIManager:close(anchor)
    local function count(rows,path)
        local total=0;for _,row in ipairs(rows) do if row.path==path then total=total+row.count end end;return total
    end
    local final=state().totals
    report.account_data_writes=count(final,'/web/book/read')-count(initial,'/web/book/read')
    report.authentication_posts=count(final,'/web/login/renewal')-count(initial,'/web/login/renewal')
    local out=assert(io.open(evidence..'/shelf-cover-cancellation.json','wb'));out:write(client:json_encode(report));out:close()
    assert(ok,failure)
    assert(report.account_data_writes==0 and report.authentication_posts==0)
end

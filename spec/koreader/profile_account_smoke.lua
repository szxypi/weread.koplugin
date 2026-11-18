-- Native profile, worker, local HTTP, SQLite and an independent child read.
return function(host,request_count,flush)
    local socket=require('socket');local UI=require('ui/uimanager')
    local original_online=host.isNetworkOnline
    local saved=host.library_db:getProfileState('account_name')
    local saved_statistics=host.library_db:getProfileState('statistics')
    local before=request_count('/api/userInfo')
    local function pump(predicate)
        local deadline=socket.gettime()+25
        while not predicate() do assert(socket.gettime()<deadline,'profile name timeout');flush();socket.sleep(.02) end
    end
    host.isNetworkOnline=function() return true end
    host:showProfile();host:cancelProfileRefresh();flush()
    local view=assert(host._profile_view)
    view._profile_buttons[3].callback()
    pump(function() return request_count('/api/userInfo')>before and not host.profile_name_request end)
    assert(request_count('/api/userInfo')==before+1,'nickname was requested more than once')
    assert(host._profile_view.data.account_name=='Synthetic Web reader','refreshed name was not displayed')
    local stored=assert(host.library_db:getProfileState('account_name'))
    assert(stored.name=='Synthetic Web reader' and stored.epoch==host.settings:get_auth_scope().epoch)
    local worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client}
    local done,result
    assert(worker:start(function()
        return require('weread.lib.library_db'):new(host.settings):getProfileState('account_name')
    end,function(value) result=value;done=true end))
    pump(function() return done end)
    assert(result and result.name==stored.name and result.epoch==stored.epoch,'independent database read differed')
    host:cancelProfileRefresh();host.isNetworkOnline=function() return false end
    host:showProfile();flush()
    assert(host._profile_view.data.account_name=='Synthetic Web reader','offline profile did not retain nickname')
    assert(request_count('/api/userInfo')==before+1,'offline profile contacted server')
    host:closeWeReadUI();host.isNetworkOnline=original_online
    if saved then assert(host.library_db:putProfileState('account_name',saved))
    else assert(host.library_db:deleteProfileStateIf('account_name',stored)) end
    local statistics=host.library_db:getProfileState('statistics')
    if saved_statistics then assert(host.library_db:putProfileState('statistics',saved_statistics))
    elseif statistics then assert(host.library_db:deleteProfileStateIf('statistics',statistics)) end
    print('PASS: profile nickname -> native refresh, owner-bound HTTP worker, SQLite child read and offline reopen')
end

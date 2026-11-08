-- Native statistics/My page through real HTTP, memory workers, UI and SQLite.
return function(plugin,count,flush_tasks,home,pump_until)
    local UIManager=require("ui/uimanager")
    local Screen=require("device").screen
    local Stats=require("weread.lib.read_stats")
    local http,ltn12,socket=require("socket.http"),require("ltn12"),require("socket")
    local settings,client=plugin.settings,plugin.client
    local old_key=settings:get("api_key")
    settings:set("api_key","");settings:flush()
    local function control(value)
        local body=client:json_encode(value)
        local _,code=http.request{url=settings.mock_endpoint.."/__control",proxy=settings.mock_endpoint,method="POST",
            source=ltn12.source.string(body),sink=ltn12.sink.null(),headers={["content-type"]="application/json",["content-length"]=#body}}
        assert(code==200)
    end
    local function wait() flush_tasks();pump_until(function() return not plugin.profile_request and not plugin.statistics_request end) end
    local function paint(name,view)
        UIManager:forceRePaint();Screen:shot(home.."/../evidence/"..name..".png")
        assert(view[1]:getSize().h==Screen:getHeight() and view[1]:getSize().w<=Screen:getWidth(),"statistics viewport exceeds screen")
    end
    local writes=count("/web/book/read")
    local gateway=count("/api/agent/gateway","/readdata/detail")
    local posts=count("/login","native_renewal")
    plugin:closeWeReadUI();plugin:showProfile();wait()
    local profile=assert(plugin._profile_view)
    assert(profile.data.has_data and #profile._calendar_cells>=28 and plugin.library_db:getProfileState("statistics").source_kind=="native",
        "keyless native profile did not persist/render calendar")
    paint("native-statistics-profile",profile)
    profile._profile_buttons[1].callback();flush_tasks()
    local goal=assert(plugin._profile_goal_dialog)
    goal:setInputText("45");goal.buttons[1][2].callback();flush_tasks()
    assert(plugin._profile_view.data.goal_minutes==45,"keyless local reading goal failed")
    plugin._profile_view._profile_buttons[2].callback();wait()
    for _,mode in ipairs({"monthly","weekly","annually","overall"}) do
        if mode~="monthly" then plugin:loadReadStats(mode,nil,plugin._read_stats_view);wait() end
        assert(plugin._read_stats_view.data.mode==mode and plugin._read_stats_view.data.source_kind=="native","statistics mode lost native access")
        paint("native-statistics-"..mode,plugin._read_stats_view)
    end
    local previous=Stats.shift_period("monthly",Stats.period_start("monthly",os.time()),-1)
    plugin:loadReadStats("monthly",previous,plugin._read_stats_view);wait()
    assert(plugin._read_stats_view.data.base_time==previous and plugin._read_stats_view.data.allow_next,"historical native month not normalized")
    local reads=count("/readdata/detail")
    plugin:closeWeReadUI()
    plugin.isNetworkOnline=function() return false end
    plugin:loadReadStats("monthly",previous)
    assert(plugin._read_stats_view and plugin._read_stats_view.data.cached and plugin._read_stats_view.data.base_time==previous
        and count("/readdata/detail")==reads,"offline exact-period cache fetched or lost statistics")
    paint("native-statistics-offline",plugin._read_stats_view)
    plugin:closeWeReadUI()
    local other=require("weread.lib.library_db"):new{data_dir=settings.data_dir,get=function(_self,key,default)
        if key=="account" then return {user_vid="90009999"} end
        return default
    end}
    assert(other:databasePath()~=plugin.library_db:databasePath() and not other:getProfileState("statistics")
        and not other:getProfileState("reading-statistics:monthly:"..previous),"statistics SQLite cache crossed accounts")
    plugin.isNetworkOnline=function() return true end
    plugin:showProfile();wait()
    control{match="/readdata/detail",times=1,status=401,delay=0}
    plugin:refreshProfile(false);wait()
    assert(plugin.library_db:getProfileState("statistics").source_kind=="native" and count("/login","native_renewal")==posts+1,
        "native profile 401 did not renew and replace whole snapshot")
    control{match="/readdata/detail",times=1,status=401,delay=0}
    plugin:loadReadStats("weekly");wait()
    assert(plugin._read_stats_view.data.source_kind=="native" and count("/login","native_renewal")==posts+2,
        "detailed statistics 401 did not recover once")
    local month_key="reading-statistics:monthly:"..Stats.period_start("monthly",os.time())
    plugin:loadReadStats("monthly",nil,plugin._read_stats_view);wait()
    local stable=plugin.library_db:getProfileState(month_key)
    stable.fetched_at=1000;assert(plugin.library_db:putProfileState(month_key,stable))
    control{match="/readdata/detail",times=1,status=429,delay=0}
    plugin:loadReadStats("monthly",nil,plugin._read_stats_view);wait()
    assert(plugin._read_stats_view.data.cached and plugin.library_db:getProfileState(month_key).fetched_at==1000
        and count("/login","native_renewal")==posts+2,"rate limiting overwrote cache or renewed")

    -- Both statistics paths are real children; suspend cleans their owners.
    plugin:closeWeReadUI();plugin:showProfile()
    local snapshot=plugin.library_db:getProfileState("statistics")
    snapshot.fetched_at=1000;assert(plugin.library_db:putProfileState("statistics",snapshot))
    control{match="/readdata/detail",times=0,delay=0.6}
    plugin:refreshProfile(false);plugin:loadReadStats("monthly")
    pump_until(function() return plugin.profile_worker.job and plugin.statistics_worker.job end)
    local heartbeat=false;UIManager:scheduleIn(0.1,function() heartbeat=true end)
    pump_until(function() return heartbeat end)
    assert(plugin.profile_request and plugin.statistics_request,"statistics HTTP blocked the UI heartbeat")
    plugin:onSuspend()
    assert(not plugin.profile_request and not plugin.statistics_request and not plugin.profile_worker.job
        and not plugin.statistics_worker.job and not plugin.busy_message,"suspend retained statistics children/busy state")
    control{match="",times=0,delay=0};plugin:onResume()
    local deadline=socket.gettime()+0.7
    while socket.gettime()<deadline do flush_tasks();socket.sleep(0.01) end
    assert(plugin.library_db:getProfileState(month_key).fetched_at==1000
        and plugin.library_db:getProfileState("statistics").fetched_at==1000,"cancelled statistics updated SQLite cache")
    assert(count("/api/agent/gateway","/readdata/detail")==gateway,"healthy keyless native statistics used gateway")
    assert(count("/web/book/read")==writes,"statistics uploaded reading state")
    plugin:closeWeReadUI();settings:set("api_key",old_key);settings:flush()
    print("PASS: keyless native My/calendar/goal -> 4 statistics tabs/history -> scoped SQLite/offline exact period -> 401 once/429 cache -> responsive children and actual suspend/no late writes")
end

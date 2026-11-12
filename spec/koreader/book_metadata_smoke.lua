-- Packaged native UI, worker pipe, HTTP and SQLite. Synthetic account only.
return function(plugin,count,flush_tasks,home,pump_until)
    local UIManager=require("ui/uimanager")
    local Screen=require("device").screen
    local http,ltn12=require("socket.http"),require("ltn12")
    local settings,client=plugin.settings,plugin.client
    local previous_key,previous_cookies=settings:get("api_key"),settings:get("cookies")
    local books=settings:get("books",{})
    local id="900025"
    local previous=books[id]
    books[id]={book_id=id,title="Cached synthetic title",progress=83,chapter_uid=99,chapter_offset=123,bookVersion=47,
        pending_upload_position={book_id=id,percent=83},pending_upload_account=plugin.library_db:accountKey()}
    settings:set("books",books);settings:flush()
    local writes=count("/web/book/read")
    local progress=count("/web/book/getProgress")+count("/api/agent/gateway","/book/getprogress")
    local function control(value)
        local body=client:json_encode(value)
        local _,code=http.request{url=settings.mock_endpoint.."/__control",proxy=settings.mock_endpoint,method="POST",
            headers={["content-type"]="application/json",["content-length"]=#body},source=ltn12.source.string(body),sink=ltn12.sink.null()}
        assert(code==200)
    end
    local function cached() return settings:get("books",{})[id] end
    local function refresh()
        plugin._book_detail_view._refresh_button.callback()
        assert(plugin.book_metadata_context and plugin.book_metadata_worker.job,"native refresh did not start in background")
    end
    local function wait() pump_until(function() return not plugin.book_metadata_context end);flush_tasks() end
    local function has_text(widget,text)
        if type(widget)~="table" then return false end
        if widget.text==text then return true end
        for index=1,#widget do if has_text(widget[index],text) then return true end end
        return false
    end
    plugin:closeWeReadUI()
    plugin:showBookMenu(cached())
    control{match="/web/reader/",times=0,delay=0.5}
    refresh()
    local current_context=plugin.book_metadata_context
    plugin:refreshBookRecord(cached(),{})
    assert(plugin.book_metadata_context==current_context,"stale native refresh cancelled the current metadata request")
    local responsive=false
    UIManager:scheduleIn(0.1,function() responsive=true end)
    pump_until(function() return responsive end)
    assert(plugin.book_metadata_context,"metadata request blocked the UI heartbeat")
    books=settings:get("books",{});books[id].progress=84;books[id].chapter_uid=100
    settings:set("books",books);settings:flush()
    wait()
    local value=cached()
    assert(value.detail_source=="web" and value.publisher=="合成出版社" and value.isbn=="9780000000000"
        and value.newRating==860 and value.categoryName=="文学 · 合成","Web metadata not persisted")
    assert(value.progress==84 and value.chapter_uid==100 and value.chapter_offset==123 and value.bookVersion==47
        and value.pending_upload_position.percent==83 and value.psvts==nil and value.token==nil,
        "metadata changed live reading state, version or credentials")
    local view=assert(plugin._book_detail_view)
    local viewport=view[1][1][2]
    assert(view.data.metadata and #view.data.metadata>=3 and viewport.dimen.h>0
        and view[1][1]:getSize().h==Screen:getHeight(),"native metadata fields or viewport absent")
    assert(has_text(view,"自写合成简介，用于原生控件验证。\n\n第二段文字与 & 符号。"),"HTML markers were not projected to native text")
    UIManager:forceRePaint();Screen:shot(home.."/../evidence/native-web-book-metadata.png")
    if viewport:onScrollPageDown() then
        UIManager:forceRePaint();Screen:shot(home.."/../evidence/native-web-book-metadata-intro.png")
    end
    local metadata_calls=count("/api/agent/gateway","/book/info")
    plugin:closeWeReadUI()
    local online=plugin.isNetworkOnline
    plugin.isNetworkOnline=function() return false end
    plugin:showBookRecord({bookId=id,title=value.title})
    assert(plugin._book_detail_view and not plugin.book_metadata_context
        and count("/api/agent/gateway","/book/info")==metadata_calls,"offline detail lost cached fields or retried")
    plugin.isNetworkOnline=online
    settings:set("api_key","synthetic-metadata-key");settings:flush()
    control{match="/book/info",times=1,status=503,delay=0}
    refresh();wait()
    assert(cached().detail_source=="web" and count("/api/agent/gateway","/book/info")==metadata_calls+1,
        "metadata gateway failure did not fall back once")
    control{match="",times=0,delay=0}
    refresh();wait()
    assert(cached().detail_source=="gateway","configured metadata did not prefer gateway")
    settings:set("api_key","");settings:flush()
    control{match="/web/reader/",times=1,status=403,delay=0}
    local updated=cached().detail_updated_at
    refresh();wait()
    assert(cached().detail_updated_at==updated and plugin._book_detail_view,"failure erased cached details")
    control{match="/web/reader/",times=0,delay=0.6}
    refresh()
    plugin.busy_message:onTapClose()
    assert(not plugin.book_metadata_context and not plugin.book_metadata_worker.job,"dismiss retained metadata child")
    local until_time=require("socket").gettime()+0.7
    while require("socket").gettime()<until_time do flush_tasks();require("socket").sleep(0.01) end
    assert(cached().detail_updated_at==updated,"cancelled metadata changed cache")
    books=settings:get("books",{});books[id].detail_updated_at=1000;settings:set("books",books);settings:flush()
    refresh()
    require("socket").sleep(0.1)
    settings:update_auth({cookies={wr_vid="900000",wr_skey="synthetic-metadata-replacement"}},{replace_cookies=true})
    wait()
    assert(cached().detail_updated_at==1000,"old credentials' metadata was committed")
    assert(count("/web/book/read")==writes
        and count("/web/book/getProgress")+count("/api/agent/gateway","/book/getprogress")==progress,
        "metadata queried or wrote reader progress")
    control{match="",times=0,delay=0}
    plugin:closeWeReadUI()
    settings:update_auth({api_key=previous_key,cookies=previous_cookies},{replace_cookies=true})
    books=settings:get("books",{});books[id]=previous;settings:set("books",books);settings:flush()
    print("PASS: native metadata refresh -> responsive memory worker -> Web/Gateway/SQLite -> plain intro and publisher/ISBN/rating; offline, failure, cancel and Cookie race; reader positions/versions unchanged")
end

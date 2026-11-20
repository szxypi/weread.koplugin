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
    -- The request must not open stale details after the user changes pages.
    plugin:closeWeReadUI()
    local refresh_progress=plugin.refreshVisibleShelfProgress
    plugin.refreshVisibleShelfProgress=function() end
    plugin:showShelfView('books')
    local owner=assert(plugin.shelf_view)
    control{match='/web/reader/',times=0,delay=0.5}
    assert(plugin:refreshBookRecord(cached(),nil,{automatic=true}) and plugin.book_metadata_context)
    plugin:showShelfView('books',nil,owner,{page=2})
    local replacement=assert(plugin.shelf_view);assert(replacement~=owner)
    wait()
    assert(not plugin._book_detail_view,'late automatic metadata opened over a different shelf page')
    assert(not cached().detail_updated_at,'late automatic metadata saved after page change')
    assert(plugin.shelf_view and plugin.shelf_view.page==replacement.page,
        'background refresh lost the selected shelf page')
    plugin:closeWeReadUI();plugin:showShelfView('books');owner=assert(plugin.shelf_view)
    assert(plugin:refreshBookRecord(cached(),nil,{automatic=true}) and plugin.book_metadata_context)
    local redrawn=false
    require('weread.ui.shelf_popup').redrawForMetadata(plugin,owner,function() redrawn=true end)
    assert(not redrawn and plugin.shelf_view==owner,'background redraw interrupted metadata')
    wait()
    assert(plugin._book_detail_view and plugin.shelf_view==owner and not redrawn,
        'metadata did not open on its original shelf')
    plugin.refreshVisibleShelfProgress=refresh_progress
    control{match='',times=0,delay=0}
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
    -- Change only the isolated on-disk book identity while the worker is
    -- waiting. The returned metadata must not overwrite it or the SQLite row.
    local prior=value;local put=plugin.library_db.putBook;local writes_after_conflict=0
    plugin.library_db.putBook=function(self,book) writes_after_conflict=writes_after_conflict+1;return put(self,book) end
    local info=plugin.showInfo;local notice
    plugin.showInfo=function(_,message) notice=message end
    control{match='/web/reader/',times=0,delay=0.5};refresh()
    books=settings:get('books',{});books[id].book_id='900026';settings:set('books',books);settings:flush()
    local conflict=cached();assert(conflict.book_id=='900026')
    wait();local after_conflict=cached()
    assert(notice and writes_after_conflict==0 and after_conflict.book_id=='900026'
        and after_conflict.title==conflict.title and after_conflict.detail_updated_at==conflict.detail_updated_at,
        'late metadata rewrote a conflicting on-disk book')
    plugin.library_db.putBook=put;plugin.showInfo=info
    books=settings:get('books',{});books[id]=prior;settings:set('books',books);settings:flush()
    writes_after_conflict=0;notice=nil
    plugin.library_db.putBook=function(self,book) writes_after_conflict=writes_after_conflict+1;return put(self,book) end
    plugin.showInfo=function(_,message) notice=message end
    refresh();books=settings:get('books',{});books[id]=nil;settings:set('books',books);settings:flush()
    wait();assert(notice and writes_after_conflict==0 and cached()==nil,
        'late metadata recreated a removed local book')
    plugin.library_db.putBook=put;plugin.showInfo=info
    books=settings:get('books',{});books[id]=prior;settings:set('books',books);settings:flush()
    control{match='',times=0,delay=0}
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
    control{match="",times=0,delay=0,web_renewal_mode='plain'}
    refresh();wait()
    assert(cached().detail_source=="gateway","configured metadata did not prefer gateway")
    settings:set("api_key","");settings:flush()
    control{match="/web/reader/",times=1,status=403,delay=0}
    local updated=cached().detail_updated_at
    refresh();wait()
    assert(cached().detail_updated_at==updated and plugin._book_detail_view,"failure erased cached details")
    local reader_path=assert(require('weread.lib.protocol').reader_url(id):match('^https://weread%.qq%.com(/.*)$'))
    local renewal=count('/web/login/renewal')
    local readers=count(reader_path)
    books=settings:get('books',{});books[id].detail_updated_at=1000;settings:set('books',books);settings:flush()
    control{match='/web/reader/',times=1,status=401,delay=0,web_renewal_mode='rotate'}
    refresh();wait()
    assert(count('/web/login/renewal')==renewal+1 and count(reader_path)==readers+2
        and cached().detail_updated_at>1000 and cached().detail_source=='web'
        and cached().progress==84 and cached().pending_upload_position.percent==83,
        'expired metadata did not renew and preserve the reader state')
    assert(require('weread.lib.web_authorization').capture(settings).cookies.wr_skey=='XXXrenewed-native',
        'metadata recovery did not save the verified receipt')
    renewal=count('/web/login/renewal');readers=count(reader_path);updated=cached().detail_updated_at
    control{match='/web/reader/',times=-1,status=401,delay=0,web_renewal_mode='rotate'}
    refresh();wait()
    assert(count('/web/login/renewal')==renewal+1 and count(reader_path)==readers+2
        and cached().detail_updated_at==updated and plugin._book_detail_view,
        'repeated metadata expiration retried indefinitely or changed cached details')
    renewal=count('/web/login/renewal');readers=count(reader_path)
    control{match='/web/reader/',times=1,status=429,delay=0}
    refresh();wait()
    assert(count('/web/login/renewal')==renewal and count(reader_path)==readers+1
        and cached().detail_updated_at==updated,'limited metadata incorrectly renewed or changed the cache')
    print('PASS: metadata Web 401 -> one verified renewal -> same detail; repeat 401 and 429 stop')
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
    control{match="",times=0,delay=0,web_renewal_mode='plain'}
    plugin:closeWeReadUI()
    settings:update_auth({api_key=previous_key,cookies=previous_cookies},{replace_cookies=true})
    books=settings:get("books",{});books[id]=previous;settings:set("books",books);settings:flush()
    print("PASS: native metadata refresh -> responsive memory worker -> Web/Gateway/SQLite -> plain intro and publisher/ISBN/rating; offline, failure, cancel and Cookie race; reader positions/versions unchanged")
end

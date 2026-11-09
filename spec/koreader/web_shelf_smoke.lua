-- Real widgets, Settings, SQLite, memory pipe and HTTP; synthetic account only.
return function(plugin, count, flush_tasks, home, pump_until)
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local http,ltn12 = require("socket.http"),require("ltn12")
    local settings,client = plugin.settings,plugin.client
    local previous = {cookies=settings:get("cookies"),api_key=settings:get("api_key"),account=settings:get("account")}
    local writes=count("/web/book/read")
    local function control(options)
        local body=client:json_encode(options)
        local _,code=http.request{url=settings.mock_endpoint.."/__control",proxy=settings.mock_endpoint,method="POST",
            headers={["content-type"]="application/json",["content-length"]=#body},
            source=ltn12.source.string(body),sink=ltn12.sink.null()}
        assert(code==200)
    end
    local login=require("weread.lib.qr_login"):new({},client,settings)
    login.login_cookies={wr_fp="1234567890"}
    login:_complete_protocol({succeed=true,webLoginVid="900000",accessToken="mock-web-access"},login.generation)
    assert(settings:is_cookie_configured() and not settings:is_api_configured(),"no-key login was discarded")
    assert(settings:auth_scope_matches(settings:get_auth_scope()),"Web login did not persist its account scope")
    plugin:onWeReadAccountChanged()
    plugin.native_authorization:chooseSource()
    local picker=UIManager:getTopmostVisibleWidget()
    picker.buttons[2][1].callback()
    UIManager:close(UIManager:getTopmostVisibleWidget())
    local gateway=count("/api/agent/gateway","/shelf/sync")
    local function refresh(success)
        local applied=false
        plugin:refreshBookshelf(nil,{on_loaded=function() applied=true end})
        pump_until(function() return not plugin.shelf_refreshing end)
        assert(applied==success,"unexpected Web shelf refresh result")
        if not success then UIManager:close(UIManager:getTopmostVisibleWidget()) end
    end
    refresh(true)
    assert(plugin.shelf_active_source=="web" and count("/api/agent/gateway","/shelf/sync")==gateway,
        "keyless shelf contacted gateway")
    local cached=plugin.library_db:getShelf()
    assert(#cached==26 and #plugin.shelf_groups==3 and cached[1]._web_shelf_version==800
        and cached[1].bookVersion==nil,"Web display version was promoted or old payload retained")
    plugin:showShelfView("books")
    flush_tasks()
    pump_until(function() return not plugin.shelf_cover_job and not plugin.shelf_cover_pending end)
    UIManager:forceRePaint()
    Screen:shot(home.."/../evidence/web-shelf-keyless.png")
    plugin:closeWeReadUI()
    local metadata_reads=count("/api/agent/gateway","/book/info")
    local book=cached[#cached]
    plugin:showBookRecord(book)
    pump_until(function() return not plugin.book_metadata_context end)
    flush_tasks()
    assert(plugin._book_detail_view and count("/api/agent/gateway","/book/info")==metadata_reads,
        "keyless book entry prompted for optional metadata instead of opening")
    UIManager:forceRePaint()
    Screen:shot(home.."/../evidence/web-book-keyless.png")
    plugin:closeWeReadUI()
    local Content=require("weread.lib.content")
    Content.ensure_reader_state(client,book)
    local chapters=Content.fetch_catalog(client,book)
    local path=Content.fetch_chapter_epub(client,settings,book,chapters[1])
    local document=require("document/documentregistry"):openDocument(path)
    assert(document and document:loadDocument(),"keyless downloaded EPUB did not load")
    document:setFontSize(Screen:scaleBySize(24))
    document:render()
    assert(document:getPageCount()>1,"keyless downloaded EPUB did not paginate")
    document:close()
    assert(not plugin:requireLogin(false,true),"key-only feature did not explain missing Skill authorization")
    assert(UIManager:getTopmostVisibleWidget().text:find("Skill",1,true),"missing-key explanation absent")
    UIManager:close(UIManager:getTopmostVisibleWidget())
    local fixtures=debug.getinfo(1,"S").source:match("^@(.*/)")
    dofile(fixtures.."book_metadata_smoke.lua")(plugin,count,flush_tasks,home,pump_until)
    dofile(fixtures.."reader_link_smoke.lua")(plugin,count,flush_tasks,home,pump_until)
    dofile(fixtures.."notes_export_smoke.lua")(plugin,count,flush_tasks,home,pump_until)
    dofile(fixtures.."mp_cache_identity_smoke.lua")(plugin,count,flush_tasks,home,pump_until)
    dofile(fixtures.."mp_download_smoke.lua")(plugin,count,flush_tasks,home,pump_until)
    dofile(fixtures.."mp_export_smoke.lua")(plugin,count,flush_tasks,home,pump_until)
    dofile(fixtures.."reader_context_smoke.lua")(plugin,count,flush_tasks,home)
    local renewals=count("/web/login/renewal")
    local mp_reads=count("/web/mp/articles")
    local auth_uid_reads=count("/api/auth/getLoginUid")
    local cookie_before=client:json_encode(settings:get("cookies"))
    plugin:fetchMPArticles({book_id="MP_WXS_900001",title="合成公众号"})
    flush_tasks()
    local mp_info=UIManager:getTopmostVisibleWidget()
    assert(mp_info.text==require("weread.lib.i18n").tr("Public-account verification is temporarily unavailable. Cached articles can still be read. Please try again later."),
        "MP verification response incorrectly requested another login")
    assert(count("/web/mp/articles")==mp_reads+2 and count("/web/login/renewal")==renewals+1
        and count("/api/auth/getLoginUid")==auth_uid_reads,"MP failure repeated renewal or started a new QR")
    assert(client:json_encode(settings:get("cookies"))==cookie_before and not plugin.busy_message,"header-less renewal erased cookies or retained loading")
    UIManager:forceRePaint();Screen:shot(home.."/../evidence/mp-verification-unavailable.png")
    UIManager:close(mp_info)
    print("PASS: MP verification failure after one successful header-less Web renewal keeps cookies and shows accurate native guidance; no QR replay")
    control{match="/web/shelf/sync",times=1,status=403,delay=0}
    refresh(false)
    assert(#plugin.library_db:getShelf()==26,"Web failure erased the shelf cache")
    control{match="/web/shelf/sync",times=0,delay=0.5}
    local applied=false
    plugin:refreshBookshelf(nil,{on_loaded=function() applied=true end})
    require("socket").sleep(0.1)
    local cookies=settings:get("cookies")
    cookies.wr_skey="mock-web-replacement"
    settings:set("cookies",cookies);settings:flush()
    pump_until(function() return not plugin.shelf_refreshing end)
    assert(not applied and #plugin.library_db:getShelf()==26,"cookie replacement accepted stale child result")
    control{match="",times=0,delay=0}
    settings:update_auth(previous,{replace_cookies=true})
    local shelf=settings:get("shelf");shelf.source="auto";settings:set("shelf",shelf);settings:flush()
    plugin:onWeReadAccountChanged()
    refresh(true)
    assert(plugin.shelf_active_source=="gateway" and count("/web/book/read")==writes,
        "keyless verification changed reading state or failed to restore the fixture")
    print("PASS: keyless Web login -> standard shelf -> async HTTP/SQLite/cover grid/book details -> downloadable paginated EPUB; failure cache/cookie race/Skill explanation; no reading writes")
end

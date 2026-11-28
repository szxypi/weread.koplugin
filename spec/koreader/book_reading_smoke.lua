-- The plugin's normal selection -> Read -> native ReaderUI -> sync workflow.
-- All HTTP is fail-closed synthetic traffic; no production account is used.
require("setupkoenv")
io.stdout:setvbuf("no")
local home, evidence = assert(os.getenv("KO_HOME")), assert(os.getenv("WEREAD_EVIDENCE"))
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
G_reader_settings:saveSetting("language", "zh_CN")
G_reader_settings:saveSetting("color_rendering", false)
G_reader_settings:saveSetting("footnote_link_in_popup", true)
require("gettext").changeLang("zh_CN")
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path
local Device = require("device")
require("document/canvascontext"):init(Device)
assert(require("weread.lib.mock_environment").save{
    enabled = true, host = "127.0.0.1", port = assert(tonumber(os.getenv("WEREAD_MOCK_PORT"))),
})
local Loader = require("pluginloader")
Loader.enabled_plugins, Loader.disabled_plugins, Loader.loaded_plugins = {}, {}, {}
for _, entry in ipairs(Loader:_discover()) do if entry.name == "weread" then Loader:_load{ entry } end end
assert(#Loader.enabled_plugins == 1, "candidate plugin not loaded")
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path
local UI = require("ui/uimanager")
UI:setRunForeverMode(); UI:setInputTimeout(0)
local Screen, socket, json = Device.screen, require("socket"), require("json")
local FM, Reader = require("apps/filemanager/filemanager"), require("apps/reader/readerui")
local function tick() UI:shiftScheduledTasksBy(-1e9); UI:setInputTimeout(0); UI:handleInput() end
local function pump(predicate)
    local deadline = socket.gettime() + 40
    while not predicate() do assert(socket.gettime() < deadline, "reading flow deadline"); tick(); socket.sleep(.01) end
end
local function shot(name) UI:forceRePaint(); Screen:shot(evidence .. "/" .. name .. ".png") end
local function press(view, label)
    for _, buttons in ipairs({ view._action_buttons or {}, view._footer_actions or {} }) do
        for _, button in ipairs(buttons) do
            if button.text == require("weread.lib.plugin_util").tr(label) then
                assert(button.enabled ~= false, "disabled reading action"); button.callback(); return
            end
        end
    end
    error("missing action: " .. label)
end
local function clean_popups(base)
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget() ~= base do UI:close(UI:getTopmostVisibleWidget()) end
end
local function shelf_row(view,id)
    for _,row in ipairs(view._item_rows) do
        if row.book and tostring(row.book.book_id or row.book.bookId)==id then return row end
    end
    error('selected book has no visible bookshelf row')
end
local function shelf_gesture(row,gesture)
    UI:forceRePaint()
    local position=require('ui/geometry'):new{x=row.dimen.x+math.floor(row.dimen.w/2),y=row.dimen.y+math.floor(row.dimen.h/2)}
    assert(row:handleEvent(require('ui/event'):new('Gesture',{ges=gesture,pos=position})))
end
FM:showFiles(home)
local fm = assert(FM.instance)
local plugin = assert(fm.weread)
if os.getenv('WEREAD_PROCESS_LOSS_REOPEN') then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)') .. 'process_loss_smoke.lua').reopen(plugin, Reader, clean_popups)
    os.exit(0)
end
local reopen = os.getenv("WEREAD_READING_REOPEN") == "1"
local reconnect = os.getenv("WEREAD_READING_RECONNECT") == "1"
local offline_progress = os.getenv("WEREAD_TEST_OFFLINE_PROGRESS") == "1"
local shelf_tap_layout=os.getenv('WEREAD_TEST_SHELF_TAP_READ')
local eink_fallback=os.getenv('WEREAD_TEST_EINK_STANDARD_FALLBACK')=='1'
local offline = reopen or reconnect
plugin.isNetworkOnline = function() return not offline end
plugin.isNetworkConnected = function() return not offline end
if offline then
    local checkpoint_path = evidence .. (reconnect and "/offline-progress-checkpoint.json" or "/reading-checkpoint.json")
    local file = assert(io.open(checkpoint_path, "rb"))
    local expected = json.decode(file:read("*a")); file:close()
    if shelf_tap_layout then
        assert(plugin.settings:get('shelf').tap_to_read==true,'tap-to-read setting did not persist')
        plugin:showBookshelf()
    else plugin:showHome() end
    local view = assert(plugin.shelf_view)
    local books = view.books
    local book
    for _, row in ipairs(books) do if tostring(row.bookId or row.book_id) == expected.book_id then book = row end end
    assert(book and book._cached and plugin.settings:get_book(expected.book_id).cached_chapters, "offline book/cache missing")
    if offline_progress then
        local config = plugin.settings:get("sync")
        config.pull_on_open, config.upload_on_close, config.ask_on_conflict = reconnect, reconnect, true
        plugin.settings:set("sync", config); plugin.settings:flush()
    end
    if shelf_tap_layout then shelf_gesture(shelf_row(view,expected.book_id),'tap')
    else view.on_select(book) end
    pump(function() return Reader.instance and Reader.instance.document.file == expected.path end)
    local reader = Reader.instance
    local current = reader.weread
    current.isNetworkOnline, current.isNetworkConnected = function() return not offline end, function() return not offline end
    pump(function() return current.progress_sync.current_book_id ~= nil end)
    assert(reader.document:isXPointerInCurrentPage(expected.xpointer), "offline reopen lost native position")
    assert(reader.weread.settings:get_book(expected.book_id).last_uploaded_position.chapter_uid == expected.chapter_uid,
        "fresh process lost acknowledged progress")
    shot("reading-offline-reopen")
    if os.getenv('WEREAD_TEST_READER_DISPLAY')=='1' and reopen then
        dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_display_smoke.lua')(
            reader,current,pump,shot,clean_popups,true,evidence)
    end
    if os.getenv('WEREAD_TEST_READER_TYPOGRAPHY')=='1' and reopen then
        dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_typography_smoke.lua')(
            reader,current,pump,shot,clean_popups,true,evidence)
    end
    if os.getenv('WEREAD_TEST_READER_MARGINS')=='1' and reopen then
        dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_margins_smoke.lua')(
            reader,current,pump,shot,clean_popups,true,evidence)
    end
    if os.getenv('WEREAD_TEST_EXCERPT_CARD')=='1' and reopen then
        dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'excerpt_card_reader_smoke.lua')(reader,current,pump,shot,clean_popups,true)
    end
    if offline_progress and reopen then
        assert(not current.progress_sync.verified, "offline reopen was marked cloud-verified")
        reader.rolling:onGotoPage(reader.document:getPageCount()); tick()
        local position = assert(current.progress_sync:capture_local())
        assert(reader:getCurrentPage() ~= expected.page, "offline test did not move")
        current:onNetworkDisconnected(); current:onFlushSettings()
        local saved = current.settings:get_book(expected.book_id)
        assert(require("weread.lib.position_mapper").same_position(saved.pending_upload_position, position)
            and saved.pending_upload_account == current.library_db:accountKey(), "flush lost unverified offline movement")
        current:onSuspend(); current:onResume()
        assert(not current.progress_sync.verified and not current.progress_sync.uploading, "offline checkpoint granted upload access")
        shot("reading-offline-pending")
        current:showHome()
        local local_row
        for _, row in ipairs(current.shelf_view.books) do
            if tostring(row.bookId or row.book_id) == expected.book_id then local_row = row end
        end
        assert(local_row and local_row._shelf_progress_local and local_row._shelf_progress == position.percent,
            "offline home replaced local movement with the old cloud snapshot")
        shot("reading-offline-home-pending")
        current:closeWeReadUI()
        expected.xpointer, expected.page, expected.position = reader.document:getXPointer(), reader:getCurrentPage(), position
        local output = assert(io.open(evidence .. "/offline-progress-checkpoint.json", "wb"))
        assert(output:write(json.encode(expected))); output:close()
    elseif reconnect then
        local saved = current.settings:get_book(expected.book_id)
        local Mapper = require("weread.lib.position_mapper")
        assert(Mapper.same_position(saved.pending_upload_position, expected.position), "fresh process lost offline intent")
        offline = false
        local function wire_posts()
            local chunks = {}
            local _, code = require("socket.http").request{ url = current.settings.mock_endpoint .. "/__state",
                proxy = current.settings.mock_endpoint, sink = require("ltn12").sink.table(chunks) }
            assert(code == 200, "mock lifetime counters unavailable")
            local count = 0
            for _, row in ipairs(json.decode(table.concat(chunks)).totals) do
                if row.path == "/web/book/read" then count = count + row.count end
            end
            return count
        end
        local before = wire_posts()
        current:onNetworkConnected()
        pump(function() return current.progress_sync.state == "awaiting_choice" end)
        local choice = assert(UI:getTopmostVisibleWidget())
        assert(choice.cancel_text == require("weread.lib.plugin_util").tr("Keep KOReader progress"), "reconnect lost conflict choice")
        assert(Mapper.same_position(current.settings:get_book(expected.book_id).pending_upload_position, expected.position),
            "cloud comparison erased offline movement before a choice")
        assert(wire_posts() == before, "reconnect wrote before the local/cloud decision")
        shot("reading-reconnect-choice")
        current:onNetworkConnected()
        choice.cancel_callback(); UI:close(choice)
        pump(function() return not current.progress_sync.uploading end)
        saved = current.settings:get_book(expected.book_id)
        local uploaded=assert(saved.last_uploaded_position)
        local source=assert(current.source_position:current())
        assert(not saved.pending_upload_position and Mapper.same_position(saved.last_local_position,expected.position)
            and uploaded.wire_basis=='filtered_xhtml_utf16' and uploaded.chapter_uid==source.chapter_uid
            and uploaded.chapter_offset==source.chapter_offset and not uploaded.summary
            and uploaded.source_position.raw_sha256==source.raw_sha256,
            "chosen offline position was not acknowledged")
        local remote = current.client:get_progress(expected.book_id)
        assert(remote.book.progress == expected.position.percent, "reconnected synthetic cloud readback differs")
        assert(wire_posts() == before + 2, "chosen upload repeated the session-entry/progress sequence")
        shot("reading-reconnect-result")
        -- A later cloud choice must discard the new local checkpoint without
        -- uploading it or recreating it when the native document closes.
        clean_popups(reader)
        reader.rolling:onGotoPage(1); tick()
        offline = true; current:onNetworkDisconnected()
        assert(current.settings:get_book(expected.book_id).pending_upload_position,
            "second offline move was not preserved")
        offline = false; current:onNetworkConnected()
        pump(function() return current.progress_sync.state == "awaiting_choice" end)
        choice = assert(UI:getTopmostVisibleWidget())
        shot("reading-reconnect-remote-choice")
        assert(wire_posts() == before + 2, "second comparison uploaded the unchecked page")
        choice.ok_callback(); UI:close(choice)
        pump(function() return current.progress_sync.verified and not current.cloud_source_request
            and not current.source_navigation.job end)
        local held=assert(current.progress_sync:current_source_target())
        assert(held.chapter_offset==uploaded.chapter_offset and held.chapter_uid==uploaded.chapter_uid,
            'cloud choice restored word fraction instead of exact source point')
        local index=assert(require('weread.lib.source_dom').open(reader.document,held.book_id,held.chapter_uid))
        assert(reader.document:isXPointerInCurrentPage(assert(index:locate(held.chapter_offset)).xpointer),
            'exact cloud target is not visible after native navigation')
        assert(not current.settings:get_book(expected.book_id).pending_upload_position,
            "chosen cloud position kept the superseded local intent")
        current:onFlushSettings()
        assert(not current.settings:get_book(expected.book_id).pending_upload_position,
            "flush recreated a local intent after accepting cloud progress")
        assert(wire_posts() == before + 2, "cloud choice started another upload")
        shot("reading-reconnect-remote-result")
        local output = assert(io.open(evidence .. "/offline-progress-result.json", "wb"))
        assert(output:write(json.encode{ result = "PASS", synthetic_only = true, unverified_checkpoint = true,
            manual_only_checkpoint = true, flush_and_suspend = true, fresh_process = true,
            native_position_restored = true, local_home_progress = true, reconnect_compared_before_write = true,
            explicit_choice_required = true, duplicate_link_event_safe = true, mock_readback = true,
            remote_choice_clears_pending = true, remote_choice_no_upload = true, flush_preserves_remote_choice = true,
            offline_new_requests = 0, chosen_updates = 1, session_entry_and_progress_posts = 2 })); output:close()
    end
    if os.getenv('WEREAD_TEST_SELECTION_THOUGHT')=='1' then
        dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'selection_thought_smoke.lua')(reader,current,pump,shot,clean_popups,true)
    end
    clean_popups(reader); reader:onClose(false)
    if reconnect then print("PASS: fresh process -> restored offline intent -> reconnect read-only comparison -> explicit local choice -> one upload sequence and mock readback")
    elseif shelf_tap_layout then print('PASS: fresh process -> bookshelf tap -> native reader restored position; zero HTTP')
    else print("PASS: fresh process -> plugin Home cached selection -> native reader restored position; zero HTTP") end
    os.exit(0)
end

plugin:showHome()
assert(plugin.shelf_view and plugin.shelf_view.on_refresh, "home is unavailable")
plugin.shelf_view.on_refresh()
pump(function() return #(plugin.library_db:getShelf() or {}) > 0 and not plugin.busy_message end)
plugin:closeWeReadUI(); plugin:showHome()
shot("reading-home")
local screenshot_smoke
if os.getenv('WEREAD_TEST_DELAYED_SCREENSHOT')=='1' then
    screenshot_smoke=dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'delayed_screenshot_smoke.lua')
    screenshot_smoke.home(plugin,fm,evidence)
end
if not eink_fallback then
    local selected
    for _, book in ipairs(plugin.library_db:getShelf()) do
        if tostring(book.bookId or book.book_id) == "900001" then selected = book end
    end
    assert(selected, "synthetic shelf book missing")
    plugin.shelf_view.on_select(selected)
    pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
    shot("reading-uncached-detail")
    press(plugin._book_detail_view, "▤ Read")
    assert(plugin.book_reading_context and not Reader.instance, "uncached Read skipped async preparation")
    shot("reading-preparing")
    plugin:cancelBookReading()
    for _i = 1, 4 do tick() end
    assert(not Reader.instance and not plugin.downloader._active_job, "cancelled preparation opened reader")

    plugin:closeWeReadUI(); plugin:showBookshelf()
    plugin.shelf_view.on_select(selected, "books")
    pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
    press(plugin._book_detail_view, "▤ Read")
    plugin:onSuspend()
    for _i = 1, 4 do tick() end
    assert(not plugin.book_reading_context and not Reader.instance, "suspended preparation opened reader")

    press(plugin._book_detail_view, "▤ Read")
    pump(function() return plugin.downloader._active_job ~= nil end)
    shot("reading-download-cancel")
    plugin:cancelBookReading()
    pump(function() return not plugin.downloader._active_job end)
    assert(not Reader.instance, "cancelled download opened reader")

    press(plugin._book_detail_view, "▤ Read")
    plugin._book_detail_view:onClose()
    for _i = 1, 4 do tick() end
    assert(not plugin.book_reading_context and not Reader.instance, "closed detail reopened reader")
end

plugin:closeWeReadUI(); plugin:showBookstore()
press(plugin.shelf_view, "For you")
pump(function() return not plugin.discovery_loading and plugin.discovery_state and #plugin.discovery_state.books > 0 end)
shot("reading-bookstore")
local store_book
for _, book in ipairs(plugin.discovery_state.books) do if tostring(book.bookId or book.book_id) == "900001" then store_book = book end end
assert(store_book, "bookstore did not return target")
local auth_case,auth_reset
if os.getenv('WEREAD_TEST_READING_AUTH_RECOVERY') then
    local run_auth=dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'book_reading_renewal_case.lua')
    auth_case,auth_reset=run_auth(plugin,os.getenv('WEREAD_TEST_READING_AUTH_RECOVERY'))
end
local fallback_error
local function arm_eink_fallback()
    if not eink_fallback then return end
    assert(plugin.settings.mock_endpoint and require('weread.lib.shelf_source').web_access(plugin.settings))
    local scope=assert(plugin.settings:get_auth_scope())
    assert(scope.vid=='900000')
    local Access=require('weread.lib.native_read_access')
    local capture=Access.capture
    local credential_store={read=function()
        return {vid = scope.vid,accessToken = 'mock-native-access',refreshToken = 'mock-native-refresh',
            deviceId = 'eink334691225'..string.rep('0',19)},1,nil,false
    end}
    Access.capture=function(settings,store) return capture(settings,store or credential_store) end
    local show_info=plugin.showInfo
    plugin.showInfo=function(self,message,...)
        fallback_error=message
        return show_info(self,message,...)
    end
    plugin.settings:set('prefer_eink_chapters',true);plugin.settings:flush()
    local payload=json.encode{match='/book/chapterInfos',times=1,status=503}
    local _,code=require('socket.http').request{
        url=plugin.settings.mock_endpoint..'/__control',method='POST',
        source=require('ltn12').source.string(payload),
        headers={['Content-Type']='application/json',['Content-Length']=tostring(#payload)},
    }
    assert(code==200,'could not configure the isolated catalog failure')
end
if shelf_tap_layout then
    local tr=require('weread.lib.plugin_util').tr
    local function find(items,label)
        for _,item in ipairs(items) do if item.text==tr(label) then return item end end
        error('missing menu item: '..label)
    end
    local settings=find(plugin:getSettingsMenuItems(),'Bookshelf view').sub_item_table_func()
    local tap=find(settings,'Tap to read on bookshelf')
    assert(not tap.checked_func(),'existing tap behavior changed by default')
    find(settings,shelf_tap_layout=='cover' and 'Cover view' or 'List view').callback()
    local function show_shelf()
        plugin:closeWeReadUI();plugin:showBookshelf()
        local view=assert(plugin.shelf_view)
        assert(view.cover_mode==(shelf_tap_layout=='cover'),'selected shelf layout did not open')
        return view,shelf_row(view,'900001')
    end
    local _,old_row=show_shelf()
    shelf_gesture(old_row,'tap')
    pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
    assert(not Reader.instance and not plugin.book_reading_context,'default tap read the book instead of showing details')
    local view,row=show_shelf()
    tap.callback()
    assert(tap.checked_func(),'tap-to-read setting was not enabled')
    old_row.callback()
    assert(not plugin._book_detail_view and not plugin.book_reading_context,'stale shelf row opened a book')
    shelf_gesture(row,'hold')
    local quick=assert(view._shelf_popup)
    shelf_gesture(row,'hold_release')
    local details
    for _,buttons in ipairs(quick.buttons) do
        for _,button in ipairs(buttons) do if button.text==tr('Book details') then details=button end end
    end
    assert(details).callback()
    pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
    assert(not Reader.instance and not plugin.book_reading_context,'hold no longer offered details')
    local selected_view,selected_row=show_shelf()
    if shelf_tap_layout=='list' and not eink_fallback then
        local FocusManager=require('ui/widget/focusmanager')
        for y,items in ipairs(selected_view.layout) do
            if items[1]==selected_row then
                selected_view:moveFocusTo(1,y,FocusManager.FORCED_FOCUS)
                break
            end
        end
        UI:forceRePaint()
        assert(selected_view:getFocusItem()==selected_row and selected_row.frame.invert)
        assert(selected_view:onPress() and plugin.book_reading_context,'focused row did not start reading')
        plugin:cancelBookReading()
        for _i=1,4 do tick() end
        assert(not Reader.instance and not plugin.book_reading_context and plugin.shelf_view==selected_view
            and UI:getTopmostVisibleWidget()==selected_view,'cancelled Press did not return to the same shelf')
        assert(selected_view:getFocusItem()==selected_row and selected_row.frame.invert,
            'cancelled direct reading lost the selected row highlight')
        print('PASS: native shelf Press, cancel reading, and retain the highlighted selection')
    end
    arm_eink_fallback()
    shelf_gesture(selected_row,'tap')
    assert(not plugin._book_detail_view,'direct shelf reading opened book details')
    assert(eink_fallback and plugin._native_direct_reading or plugin.book_reading_context,'shelf tap did not start uncached reading')
    require('weread.ui.shelf_popup').redrawForMetadata(plugin,selected_view,function()
        error('automatic shelf refresh interrupted direct reading')
    end)
elseif os.getenv('WEREAD_TEST_QUICK_READ')=='1' then
    local view=plugin.shelf_view
    local cell
    for _,item in ipairs(view._item_rows) do if item.book==store_book then cell=item end end
    assert(cell,'selected bookstore book lacks a cover cell')
    UI:forceRePaint()
    local event=require('ui/event')
    local pos=require('ui/geometry'):new{x=cell.dimen.x+math.floor(cell.dimen.w/2),y=cell.dimen.y+math.floor(cell.dimen.h/2)}
    assert(cell:handleEvent(event:new('Gesture',{ges='hold',pos=pos})))
    local dialog=assert(view._shelf_popup)
    assert(cell:handleEvent(event:new('Gesture',{ges='hold_release',pos=pos})))
    local read
    for _,row in ipairs(dialog.buttons) do for _,button in ipairs(row) do
        if button.text==require('weread.lib.plugin_util').tr('Read now') then read=button end
    end end
    assert(read);read.callback()
else
    plugin.shelf_view.on_select(store_book)
    pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
    arm_eink_fallback()
    press(plugin._book_detail_view, "▤ Read")
end
if eink_fallback then
    local dialog
    assert(plugin._native_direct_reading,'the preferred read action did not choose the E-Ink channel')
    pump(function()
        local job=plugin._native_direct_reading
        dialog=job and job.confirm
        return dialog~=nil or fallback_error~=nil or not job
    end)
    assert(dialog,fallback_error or 'native recovery did not show its standard reading choice')
    assert(dialog.ok_text==require('weread.lib.plugin_util').tr('Use standard reading') and not Reader.instance
        and not plugin.book_reading_context,'standard reading did not wait for confirmation')
    UI:forceRePaint();dialog.ok_callback()
    assert(not plugin._native_direct_reading and plugin.book_reading_context,'standard reading did not take over')
end
local auth_mode=os.getenv('WEREAD_TEST_READING_AUTH_RECOVERY')
if auth_mode=='repeat401' or auth_mode=='forbidden' or auth_mode=='limited' then
    pump(function() return not plugin.book_reading_context end)
    assert(not Reader.instance and plugin._book_detail_view,'persistent 401 opened a reader or lost the book')
    auth_reset();clean_popups(plugin._book_detail_view);press(plugin._book_detail_view,'▤ Read')
end
pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.document:getPageCount() > 1 end)
local reader = Reader.instance
if auth_case then auth_case(reader) end
assert(reader.document.file:match("%.epub$"), "Read did not open the native EPUB engine")
assert(not plugin.book_reading_context and not plugin._book_detail_view and not plugin.shelf_view,
    "plugin views survived native handoff")
shot("reading-native-reader")
if os.getenv('WEREAD_TEST_READER_DISPLAY')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_display_smoke.lua')(
        reader,reader.weread,pump,shot,clean_popups,false,evidence)
end
if screenshot_smoke then screenshot_smoke.reader(reader.weread,reader) end
if os.getenv('WEREAD_TEST_READER_PROGRESS')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_progress_smoke.lua')(
        reader,reader.weread,pump,shot,clean_popups,false)
end
if os.getenv('WEREAD_TEST_READER_TYPOGRAPHY')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_typography_smoke.lua')(
        reader,reader.weread,pump,shot,clean_popups,false,evidence)
end
if os.getenv('WEREAD_TEST_READER_MARGINS')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_margins_smoke.lua')(
        reader,reader.weread,pump,shot,clean_popups,false,evidence)
end
-- Exercise the actual downloaded book through its bound plugin and native tap
-- routing, in addition to the standalone layout/preference fixture.
local note = "这是自写的原书脚注。"
assert(#(reader.document:findAllText(note, false, 0, 10, false, 0) or {}) == 1,
    "downloaded chapter contains duplicate native note text")
local origin, note_link = reader.document:getXPointer(), nil
for page = 1, reader.document:getPageCount() do
    reader.rolling:onGotoPage(page); tick()
    note_link = reader.document:getPageLinks()[1]
    if note_link then break end
end
assert(note_link and note_link.segments[1], "downloaded book lacks its native footnote link")
local segment = note_link.segments[1]
local source_page = reader:getCurrentPage()
reader.link:onTap(nil, { pos = require("ui/geometry"):new{
    x = math.floor((segment.x0 + segment.x1) / 2), y = math.floor((segment.y0 + segment.y1) / 2),
} })
local popup = assert(UI:getTopmostVisibleWidget())
local first = popup.html and popup.html:find(note, 1, true)
assert(first and not popup.html:find(note, first + #note, true) and reader:getCurrentPage() == source_page,
    "downloaded footnote popup duplicated text or changed page")
shot("reading-footnote-popup"); popup:onClose()
reader:handleEvent(require("ui/event"):new("GotoXPointer", origin)); tick()
reader.rolling:onGotoPage(2); tick()
assert(reader:getCurrentPage() == 2, "native page turn failed")
local current = reader.weread
current.isNetworkOnline, current.isNetworkConnected = function() return true end, function() return true end
if os.getenv('WEREAD_TEST_PROGRESS_PAGE_HOTPATH')=='1' then
    local sync=current.progress_sync
    pump(function() return sync.current_book_id and not sync.pulling and not sync.interval.cycle end)
    local reads,captures=0,0
    local marker_method,capture_method=sync._recovery_marker,sync.capture_local
    local marker_own,capture_own=rawget(sync,'_recovery_marker'),rawget(sync,'capture_local')
    sync._recovery_marker=function(self,...) reads=reads+1;return marker_method(self,...) end
    sync.capture_local=function(self,...) captures=captures+1;return capture_method(self,...) end
    reader.rolling:onGotoPage(1);tick();reader.rolling:onGotoPage(2);tick()
    local position=assert(sync:capture_local())
    assert(reads==0 and captures>=3 and sync.local_position
        and require('weread.lib.position_mapper').same_position(position,sync.local_position),
        'page update checked an unused recovery marker or lost local movement')
    sync._recovery_marker,sync.capture_local=marker_own,capture_own
    local file=assert(io.open(evidence..'/progress-page-hotpath.json','wb'))
    file:write(json.encode{result='PASS',page_updates=2,recovery_marker_reads=reads,local_captures=captures});file:close()
end
if os.getenv("WEREAD_TEST_PROGRESS_RESPONSE") == "1" then
    local HTTP, LTN = require("socket.http"), require("ltn12")
    local function request(path, data)
        local chunks, raw = {}, data and json.encode(data)
        local _, code = HTTP.request{url=current.settings.mock_endpoint..path,proxy=current.settings.mock_endpoint,
            method=raw and "POST" or "GET",source=raw and LTN.source.string(raw) or nil,
            headers=raw and {["Content-Type"]="application/json",["Content-Length"]=tostring(#raw)} or {},
            sink=LTN.sink.table(chunks)}
        assert(code==200);return json.decode(table.concat(chunks))
    end
    local function writes()
        local count=0
        for _i,row in ipairs(request("/__state").totals) do if row.path=="/web/book/read" then count=count+row.count end end
        return count
    end
    current:onFlushSettings()
    local id=assert(current:detectWeReadBook())
    local pending=assert(current.settings:get_book(id).pending_upload_position)
    local Mapper=require("weread.lib.position_mapper")
    local before,xpointer=writes(),reader.document:getXPointer()
    local cases={"foreign","aliases","range","offset","ambiguous","rejected"}
    for _i,mode in ipairs(cases) do
        request("/__control",{progress_response=mode})
        local context_book=current.settings:get_book(id)
        local context_keys={"chapter_uid","chapter_idx","chapter_offset","progress","summary","psvts","pclts","token"}
        local original={}
        for _j,key in ipairs(context_keys) do original[key]=context_book[key] end
        assert(not current.read_report:_merge_remote_progress(id,context_book),"report context accepted invalid Gateway data")
        for _j,key in ipairs(context_keys) do assert(context_book[key]==original[key],"report context changed after rejection") end
        assert(current:onWeReadSyncProgress())
        pump(function() return not current.progress_sync.pulling and not current.cloud_source_request
            and not current.source_navigation.job end)
        assert(current.progress_sync.state=="error" and not current.progress_sync.verified,"invalid cloud progress was accepted")
        assert(reader.document:getXPointer()==xpointer,"invalid response moved the reader")
        assert(Mapper.same_position(current.settings:get_book(id).pending_upload_position,pending),"invalid response erased local intent")
        assert(writes()==before,"invalid response started a cloud write")
        local position,why=current.progress_sync:position_for_report(id)
        assert(not position and why=="progress_unverified","reporter used unverified progress")
        if mode~="rejected" then
            local message=assert(UI:getTopmostVisibleWidget())
            local key=(mode=="foreign" or mode=="aliases")
                and "WeRead returned a position that does not match this book.\nYour current position is kept. Please try syncing again later."
                or "WeRead's reading position could not be verified.\nYour current position is kept. Please try syncing again later."
            assert(message.text==require("weread.lib.plugin_util").tr(key),"invalid progress lacks a clear native message")
            if mode=="aliases" then shot("reading-progress-response-rejected") end
        end
        clean_popups(reader)
    end
    request("/__control",{progress_response="plain"})
    local valid_context=current.settings:get_book(id)
    assert(current.read_report:_merge_remote_progress(id,valid_context),"valid Gateway report context was rejected")
    local output=assert(io.open(evidence.."/reading-progress-response-result.json","wb"))
    assert(output:write(json.encode{result="PASS",synthetic_only=true,cases=#cases,cloud_posts_during_rejection=0,
        local_checkpoint_preserved=true,native_location_preserved=true,reporting_blocked=true,
        read_report_context_checked=true}));output:close()
end
if os.getenv("WEREAD_TEST_OWNER_ROUNDTRIP") then
    dofile(debug.getinfo(1,"S").source:match("^@(.*/)") .. "owner_progress_roundtrip_smoke.lua")(
        reader,current,pump,clean_popups)
end
assert(current:onWeReadSyncProgress(), "reader sync action failed")
pump(function() return not current.progress_sync.pulling end)
local choice = UI:getTopmostVisibleWidget()
if choice and choice.cancel_text == require("weread.lib.plugin_util").tr("Keep KOReader progress") then
    shot("reading-sync-choice"); choice.cancel_callback(); UI:close(choice)
end
pump(function() return not current.progress_sync.uploading end)
local book_id = assert(current:detectWeReadBook())
local saved = assert(current.settings:get_book(book_id))
assert(saved.last_uploaded_position and not saved.pending_upload_position, "sync action did not persist acknowledgement")
local remote = current.client:get_progress(book_id)
assert(remote.book.progress == saved.last_uploaded_position.percent, "synthetic cloud readback differs")
local last_chapter=os.getenv('WEREAD_TEST_LONG_READING_CATALOG')
if last_chapter then
    local chapters=assert(current.library_db:getChapters(book_id))
    assert(#chapters==tonumber(last_chapter) and tostring(chapters[#chapters].chapterUid)==last_chapter,
        'the complete long catalog was not retained')
    assert(tostring(saved.last_uploaded_position.chapter_uid)==last_chapter
        and saved.last_uploaded_position.chapter_idx==tonumber(last_chapter)
        and tostring(remote.book.chapterUid)==last_chapter and remote.book.chapterIdx==tonumber(last_chapter),
        'the final chapter did not round-trip through the long catalog')
end
shot("reading-sync-result")
if os.getenv('WEREAD_TEST_PROCESS_LOSS') then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)') .. 'process_loss_smoke.lua').prepare(reader, current)
    error('whole-reader crash fixture unexpectedly returned')
end
if os.getenv('WEREAD_TEST_SOURCE_UPLOAD')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'source_upload_smoke.lua')(reader,current,pump,clean_popups)
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'progress_interval_smoke.lua')(reader,current,pump,shot,clean_popups)
end
if os.getenv("WEREAD_TEST_PROGRESS_CONFIRMATION") == "1" then
    dofile(debug.getinfo(1, "S").source:match("^@(.*/)") .. "progress_confirmation_smoke.lua")(
        reader, current, pump, shot, clean_popups)
end
if os.getenv('WEREAD_TEST_SOURCE_RECOVERY')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'source_recovery_smoke.lua')(reader,current,pump,clean_popups)
end
if os.getenv('WEREAD_TEST_PROGRESS_RECOVERY')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'progress_fetch_recovery_smoke.lua')(reader,current,pump,clean_popups)
end
if os.getenv('WEREAD_TEST_RECOVERY_SAVE_RETRY')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'recovery_save_retry_smoke.lua')(reader,current,pump,shot,clean_popups)
end
if os.getenv('WEREAD_TEST_SHELF_MEMBERSHIP_WRITE')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'shelf_membership_write_smoke.lua')(reader,current,pump,shot,clean_popups)
end
if os.getenv('WEREAD_TEST_FINISH_CHANGE')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'finish_reader_smoke.lua')(reader,current,pump,shot,clean_popups)
end
if os.getenv('WEREAD_TEST_SELECTION_THOUGHT')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'selection_thought_smoke.lua')(reader,current,pump,shot,clean_popups)
end
if os.getenv('WEREAD_TEST_EXCERPT_CARD')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'excerpt_card_reader_smoke.lua')(reader,current,pump,shot,clean_popups)
end
local checkpoint = { book_id = book_id, path = reader.document.file,
    xpointer = reader.document:getXPointer(), chapter_uid = saved.last_uploaded_position.chapter_uid,
    synthetic_only = true, native_reader = true, page = reader:getCurrentPage() }
clean_popups(reader)
if os.getenv('WEREAD_TEST_SOURCE_UPLOAD')=='1' then
    local closed=dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'source_close_smoke.lua')(reader,current,pump,clean_popups)
    for key,value in pairs(closed) do checkpoint[key]=value end
else reader:onClose(false) end
local output = assert(io.open(evidence .. "/reading-checkpoint.json", "wb"))
assert(output:write(json.encode(checkpoint))); output:close()
print("PASS: plugin Home/shelf/store -> uncached Read -> cancellable preparation -> download -> native ReaderUI -> page turn -> sync -> synthetic readback")

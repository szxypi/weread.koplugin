package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local dialogs,closed_views = {},{}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, dialog) dialogs[#dialogs + 1] = dialog end,
        close = function(_self,view) closed_views[#closed_views+1]=view end,
        nextTick = function(_self, callback) callback() end,
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end
local subprocess_runs, subprocess_payload = 0, nil
package.preload["ffi/util"] = function()
    return {
        runInSubProcess = function(callback)
            subprocess_runs = subprocess_runs + 1
            callback(100 + subprocess_runs, 200 + subprocess_runs)
            return 100 + subprocess_runs, 200 + subprocess_runs
        end,
        writeToFD = function(_fd, data) subprocess_payload = data return true end,
        isSubProcessDone = function() return true end,
        terminateSubProcess = function() end,
        readAllFromFD = function() local data = subprocess_payload subprocess_payload = nil return data end,
    }
end
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_self, value) return value end,
        },
    }
end
for _, name in ipairs({
    "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/inputdialog",
    "ui/widget/progressbardialog", "ui/widget/textviewer",
}) do
    package.preload[name] = function() return {} end
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, data)
        data.movable = { {} }
        return data
    end }
end
package.preload["weread.lib.book_reviews"] = function() return {} end
package.preload["weread.ui.book_reviews_view"] = function() return {} end
package.preload["weread.lib.content"] = function() return {} end
local cached_covers = {}
local cover_path_lookups = 0
local fake_cover_cache = {
    MAX_IMAGE_BYTES = 3 * 1024 * 1024,
    pathFor = function(_self, book)
        cover_path_lookups = cover_path_lookups + 1
        return cached_covers[book]
    end,
    store = function(_self, book)
        cached_covers[book] = "/covers/" .. tostring(book.bookId) .. ".jpg"
        return cached_covers[book]
    end,
    prune = function() return 0 end,
    sourcePathFor = function() return nil end,
}
package.preload["weread.lib.cover_cache"] = function()
    return {
        new = function() return fake_cover_cache end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function(id) return tostring(id):match("^MP_WXS_") ~= nil end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function() return false end,
    }
end

local shown = {}
package.preload["weread.ui.library_view"] = function()
    return {
        getLayout = function(cover)
            if cover then
                return require("weread.lib.cover_layout").calculate{ width = 600, height = 800, reserved_height = 127 }
            end
            return { page_size = 10 }
        end,
        show = function(data, callbacks)
            shown[#shown + 1] = { data = data, callbacks = callbacks }
            local source = data.mode == "public_account" and data.accounts or data.books
            local page_count = math.max(1, math.ceil(#source / data.page_size))
            local page = math.max(1, math.min(data.page or 1, page_count))
            return { page = page, page_count = page_count, page_size = data.page_size,
                on_refresh = callbacks.on_refresh,
                setRefreshing = function(self, busy) self.refreshing = busy end,
                getScrollOffset = function() return { x = 0, y = 125 } end,
            }
        end,
    }
end

G_reader_settings = {
    readSetting = function(_self, key)
        return key == "items_per_page" and 14 or nil
    end,
}

local Library = require("weread.ui.library")
local shelf = {}
for index = 1, 1000 do
    shelf[index] = { bookId = tostring(index), title = "Book " .. tostring(index) }
end
local shelf_settings = { sort_order = "time_desc", paginated = true, view_mode = "list" }
local host = {
    shelf_regular = shelf,
    shelf_mp = {},
    settings = {
        set = function() end, flush = function() end,
        get = function(_self, key, default)
            if key == "books" then return {} end
            if key == "shelf" then return shelf_settings end
            return default
        end,
    },
    bookMatchesFilters = function() return true end,
    isBookDownloaded = function() return false end,
    shelfSortSummary = function() return "Recent" end,
    shelfFilterSummary = function() return "All" end,
    showShelfSortOptions = function() end,
    showShelfFilterOptions = function() end,
    isNetworkOnline = function() return false end,
    safeCallback = function(_self, _label, callback) return callback end,
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

host:showShelfView("books", nil, nil, {})
expect(shown[1].data.paged == true, "bookshelf did not enable pagination by default")
expect(shown[1].data.page_size == 10, "bookshelf used the wrong page size")
expect(#shown[1].data.books == 1000, "pagination discarded full shelf search data")

local prepared_books = shown[1].data.books
shown[1].callbacks.on_page_changed(7)
expect(shown[2].data.page == 7, "bookshelf page change was not retained")
expect(shown[2].data.books == prepared_books,
    "page change recomputed the prepared bookshelf")

shelf_settings.paginated = false
host:showShelfView("books", nil, shown[2], {})
expect(shown[3].data.paged == false,
    "bookshelf ignored the continuous-scroll preference")

shelf_settings.paginated = true
shelf_settings.sort_order = "name_asc"
host.shelf_regular = {
    { bookId = "z", title = "Zulu", visible = true },
    { bookId = "b", title = "Beta", visible = false },
    { bookId = "a", title = "Alpha", visible = true },
}
host.bookMatchesFilters = function(_self, book) return book.visible end
host:showShelfView("books", nil, shown[3], {})
expect(#shown[4].data.books == 2
        and shown[4].data.books[1].title == "Alpha"
        and shown[4].data.books[2].title == "Zulu",
    "bookshelf did not filter and sort the full result before pagination")
host:showShelfView("books", "zul", shown[4], {})
expect(#shown[5].data.books == 1 and shown[5].data.books[1].title == "Zulu",
    "bookshelf search did not run over the full filtered shelf")

host.shelf_view_pages.books = 7
host.bookMatchesFilters = function() return false end
host.showShelfFilterOptions = function(_self, callback) callback() end
shown[5].callbacks.on_filter()
expect(#shown[6].data.books == 0 and shown[6].data.paged == true,
    "bookshelf filter did not preserve an empty paged result")
expect(shown[6].data.page == 1 and host.shelf_view_pages.books == 1,
    "empty filtered bookshelf did not reset and clamp to page one")

shelf_settings.view_mode = "cover"
shelf_settings.paginated = false
shelf_settings.sort_order = "default"
host.bookMatchesFilters = function() return true end
host.shelf_regular = shelf
host.shelf_mp = {
    { bookId = "MP_WXS_1", title = "Account 1", cover = "http://wx.qlogo.cn/avatar-1" },
    { bookId = "MP_WXS_2", title = "Account 2", cover = "http://wx.qlogo.cn/avatar-2" },
}
host:showShelfView("books", nil, shown[6], {})
expect(shown[7].data.cover_mode == true and shown[7].data.paged == true,
    "cover view did not enforce lightweight page rendering")
expect(shown[7].data.page_size == 9,
    "cover view did not limit the current page to nine books")
host:showShelfView("public_account", nil, shown[7], {})
expect(shown[8].data.cover_mode == true and shown[8].data.paged == true
        and shown[8].data.page_size == 9,
    "public-account shelf did not adopt the shared cover preference")

local cover_requests = {}
for index = 1, 12 do shelf[index].cover = "https://cdn.example/" .. tostring(index) end
host.isNetworkOnline = function() return true end
host.client = {
    get_binary = function(_self, url, options)
        cover_requests[#cover_requests + 1] = { url = url, options = options }
        return "\255\216\255cover"
    end,
}
cover_path_lookups = 0
host:showShelfView("books", nil, shown[8], {})
expect(shown[9].data.cover_loading[shelf[1]] == true,
    "uncached online cover did not show its loading state")
expect(#cover_requests == 9,
    "cover view fetched books outside the current nine-item page: "
        .. tostring(#cover_requests) .. " lookups=" .. tostring(cover_path_lookups)
        .. " page=" .. tostring(shown[9] and shown[9].data.page))
expect(subprocess_runs == 9,
    "cover network and thumbnail work did not run in background subprocesses")
expect(cover_requests[1].options.skip_cookie == true
        and cover_requests[1].options.persist_response_cookies == false
        and cover_requests[1].options.max_bytes == fake_cover_cache.MAX_IMAGE_BYTES
        and cover_requests[1].options.sensitive == true,
    "public cover request did not suppress account credentials")
expect(#shown == 10 and shown[10].data.cover_paths[shelf[1]] ~= nil,
    "cover batch did not refresh the page once with cached paths")
expect(shown[10].data.cover_loading[shelf[1]] ~= true,
    "cached cover incorrectly remained in its loading state")

local requests_before_unsafe_url = #cover_requests
local unsafe_view = { page = 1 }
host.shelf_view = unsafe_view
host.shelf_cover_generation = host.shelf_cover_generation + 1
host:fetchVisibleShelfCovers(unsafe_view, {
    { bookId = "unsafe", cover = "file:///private/cover.jpg" },
}, {})
expect(#cover_requests == requests_before_unsafe_url,
    "cover loader accepted a non-HTTPS cover source")

local requests_before_qlogo = #cover_requests
local qlogo_view = { page = 1, page_size = 1 }
host.shelf_view = qlogo_view
host.shelf_cover_generation = host.shelf_cover_generation + 1
host:fetchVisibleShelfCovers(qlogo_view, {
    { bookId = "MP_WXS_avatar", cover = "http://wx.qlogo.cn/avatar" },
}, {})
expect(#cover_requests == requests_before_qlogo + 1
        and cover_requests[#cover_requests].url == "https://wx.qlogo.cn/avatar",
    "public-account avatar cover was not upgraded to HTTPS and fetched")

-- Groups are projected once per snapshot and share the existing shelf records.
local grouped_books = {}
for index = 1, 30 do grouped_books[index] = { bookId = tostring(index), title = "Group book " .. index } end
local membership = {}
for index = 1, 20 do membership[index] = tostring(index) end
local archives = {
    { archiveId = 7, name = "History", bookIds = membership },
    { archiveId = 8, name = "Empty", bookIds = {} },
    { archiveId = 9, name = "Accounts", bookIds = { "MP_WXS_1" } },
}
shelf_settings.view_mode = "list"
shelf_settings.paginated = true
host.isNetworkOnline = function() return false end
host:applyShelfSnapshot(grouped_books, archives)
host:showShelfView("books")
local groups = host.shelf_groups
expect(#groups == 3 and groups[1].books[1] == grouped_books[1],
    "snapshot groups were not projected onto the shared book records")
-- Multi-group choices persist per account and never infer a missing group as
-- empty when an incomplete snapshot is shown.
local group_account='account-a';local profiles={};local fail_save=false
host.library_db={accountKey=function() return group_account end,
    getProfileState=function(_self,key) return profiles[group_account] and profiles[group_account][key] end,
    putProfileState=function(_self,key,value)
        if fail_save then return false end
        profiles[group_account]=profiles[group_account] or {};profiles[group_account][key]=value;return true
    end}
host.showInfo=function(_self,text) host.info=text end
host._shelf_multi_loaded=nil;host:applyShelfSnapshot(grouped_books,archives);host:showShelfView('books')
shown[#shown].callbacks.on_select_groups({'archive:7','archive:8'})
expect(#shown[#shown].data.books==20 and #shown[#shown].data.group_keys==2,'multi-group union missing books')
expect(#profiles['account-a'].shelf_multi_groups_v1.keys==2,'multi-group selection not saved')
shown[#shown].callbacks.on_select_groups({'__ungrouped__'})
local all_ids={};for i=1,30 do all_ids[i]=tostring(i) end
host:applyShelfSnapshot(grouped_books,{{archiveId=7,name='History',bookIds=all_ids}});host:showShelfView('books')
expect(#shown[#shown].data.books==0 and #shown[#shown].data.group_keys==1,
    'an empty remembered uncategorized group incorrectly showed the entire shelf')
host:applyShelfSnapshot(grouped_books,archives);host:showShelfView('books')
shown[#shown].callbacks.on_select_groups({'archive:7','archive:8'})
host._shelf_multi_loaded=nil;host:applyShelfSnapshot(grouped_books,archives);host:showShelfView('books')
expect(#shown[#shown].data.group_keys==2 and #shown[#shown].data.books==20,'saved selection not restored')
host:applyShelfSnapshot(grouped_books,{archives[1]});host:showShelfView('books')
expect(#shown[#shown].data.books==30 and #shown[#shown].data.group_keys==2,'partial snapshot lost selection or hid books')
host.shelf_group_key='archive:7';host:showShelfView('books')
expect(#shown[#shown].data.books==30,'stale single-group state narrowed unavailable multi-group selection')
host.shelf_group_key=nil
host:applyShelfSnapshot(grouped_books,archives);host:showShelfView('books')
expect(#shown[#shown].data.group_keys==2 and #shown[#shown].data.books==20,'full snapshot did not restore remembered groups')
local stale_multi=shown[#shown].callbacks.on_select_groups;group_account='account-b';stale_multi({'archive:8'})
expect(not profiles['account-b'],'stale account callback saved another account selection')
host:applyShelfSnapshot(grouped_books,archives);host:showShelfView('books')
expect(#shown[#shown].data.group_keys==0 and #shown[#shown].data.books==30,'selection leaked between accounts')
shown[#shown].callbacks.on_select_groups({'archive:missing'})
expect(host.info=='Remove unavailable groups before applying.' and #shown[#shown].data.group_keys==0,
    'unavailable group was accepted or did not report a useful error')
fail_save=true;shown[#shown].callbacks.on_select_groups({'archive:8'});fail_save=false
expect(#shown[#shown].data.group_keys==0 and host.info=='Could not save the selected groups.', 'save failure applied an unpersisted filter')
group_account='account-a';host:applyShelfSnapshot(grouped_books,archives);host:showShelfView('books')
expect(#shown[#shown].data.group_keys==2,'returning to an account lost its selection')
shown[#shown].callbacks.on_select_group(nil)
expect(#profiles['account-a'].shelf_multi_groups_v1.keys==0 and #shown[#shown].data.group_keys==0,'all books did not clear persistent selection')
host.library_db=nil;host._shelf_multi_loaded=nil;host:applyShelfSnapshot(grouped_books,archives);host:showShelfView('books')
shown[#shown].callbacks.on_select_group("archive:7")
expect(shown[#shown].data.mode == "books" and #shown[#shown].data.books == 20
        and shown[#shown].data.group_label == "History", "group created a separate content mode")
local duplicate_archives={
    {archiveId=7,name='First',bookIds={'1'}},
    {archiveId=7,name='Second',bookIds={'2'}},
}
host:applyShelfSnapshot(grouped_books,duplicate_archives);host:showShelfView('books')
expect(host.shelf_group_key==nil and #shown[#shown].data.books==30,
    'ambiguous refreshed group kept filtering the bookshelf')
local count_before_duplicate=#shown
shown[#shown].callbacks.on_select_group('archive:7')
expect(#shown==count_before_duplicate and host.shelf_group_key==nil
    and host.info=='This group is unavailable. Refresh the bookshelf and try again.',
    'ambiguous group selection opened the first matching group')
host.shelf_group_key='archive:7'
host:showShelfView('books',nil,nil,{page=2,prepared_shelf={books={grouped_books[1]},accounts={}}})
expect(host.shelf_group_key==nil and shown[#shown].data.page==1 and #shown[#shown].data.books==30,
    'ambiguous stored selection reused a stale prepared shelf')
host:applyShelfSnapshot(grouped_books,archives);host:showShelfView('books')
shown[#shown].callbacks.on_select_group('archive:7')
groups=host.shelf_groups
shown[#shown].callbacks.on_page_changed(2)
expect(host.shelf_groups == groups and shown[#shown].data.page == 2,
    "paging rebuilt groups or lost the selected page")
shown[#shown].callbacks.on_switch("public_account")
shown[#shown].callbacks.on_switch("books")
expect(shown[#shown].data.group_key == "archive:7" and shown[#shown].data.page == 2,
    "switching content type discarded the book group or page")
shown[#shown].callbacks.on_select_group("archive:8")
expect(#shown[#shown].data.books == 0, "empty group fell back to the entire shelf")
shown[#shown].callbacks.on_select_group("__ungrouped__")
expect(#shown[#shown].data.books == 10, "uncategorized group has wrong membership")
host:applyShelfSnapshot(grouped_books,{{archiveId=7,name='History',bookIds=all_ids}});host:showShelfView('books')
expect(host.shelf_group_key=='__ungrouped__' and #shown[#shown].data.books==0,
    'single uncategorized selection unexpectedly showed all books after its last book was grouped')
host:applyShelfSnapshot(grouped_books,archives);host:showShelfView('books')
expect(host.shelf_group_key=='__ungrouped__' and #shown[#shown].data.books==10,
    'single uncategorized selection did not recover when ungrouped books returned')
shown[#shown].callbacks.on_select_group("archive:7")
for index = 1, 12 do grouped_books[index].cover = "https://cdn.example/group-" .. index end
host.isNetworkOnline = function() return true end
shown[#shown].callbacks.on_display_change("view_mode", "cover")
expect(shown[#shown].data.cover_mode and shown[#shown].data.group_key == "archive:7",
    "display mode change discarded the group")
host.isNetworkOnline = function() return false end
shown[#shown].callbacks.on_display_change("view_mode", "list")
shown[#shown].callbacks.on_page_changed(2)

local pending, fetches, written_archives
host.requireLogin = function() return true end
host.showBusy = function() end
host.closeBusy = function() end
host.showInfo = function() end
host.runOnlineTask = function(_self, _label, callback) pending = callback return true end
host.client.get_shelf = function()
    fetches = (fetches or 0) + 1
    return { books = grouped_books, archive = { archives[2], archives[1] } }
end
host.library_db = { cacheShelf = function(_self, _books, value) written_archives = value end }
local cache_notice
host.showTransientInfo=function(_self,text) cache_notice=text end
local before_refresh = shown[#shown]
local cover_generation = host.shelf_cover_generation
host.shelf_cover_pending = { view = host.shelf_view }
before_refresh.callbacks.on_refresh()
before_refresh.callbacks.on_refresh()
expect(host.shelf_refreshing and fetches == nil, "refresh was not scheduled or guarded")
expect(host.shelf_cover_generation > cover_generation and host.shelf_cover_pending == nil,
    "refresh left a thumbnail batch able to replace the view")
pending()
expect(fetches == 1 and written_archives[2].archiveId == 7 and not host.shelf_refreshing,
    "refresh duplicated requests or omitted archive caching")
expect(shown[#shown].data.page == 2 and shown[#shown].data.group_key == "archive:7"
        and shown[#shown].data.scroll_offset.y == 125,
    "refresh lost group, page or scroll position after archive reorder")
expect(cache_notice and cache_notice:find('offline',1,true),
    'visible shelf refresh did not report a failed offline snapshot')
local saved_result,refreshed_snapshot
host:refreshBookshelf(nil,{on_loaded=function(saved,snapshot) saved_result,refreshed_snapshot=saved,snapshot end})
pending()
expect(saved_result==false and refreshed_snapshot.books==grouped_books and refreshed_snapshot.archives==written_archives,
    'home refresh did not receive the fresh network snapshot when cache saving failed')
host:showShelfView('books',nil,nil,{page=2})

local original_info=host.showInfo
local incomplete_info
host.showInfo=function(_self,message) incomplete_info=message end
local before_incomplete=shown[#shown]
host.library_db.getShelf=function() return grouped_books end
host.library_db.getShelfArchives=function() return archives end
host.client.get_shelf=function() return {books={{bookId='new',title='Incomplete'}}} end
local previous_write=written_archives
before_incomplete.callbacks.on_refresh();pending()
expect(shown[#shown]==before_incomplete and written_archives==previous_write and host.shelf_group_key=='archive:7'
    and incomplete_info and incomplete_info:find('previous complete',1,true),
    'missing group data replaced the current grouped shelf or cached snapshot')
local incomplete_home
host:refreshBookshelf(nil,{on_loaded=function(saved,snapshot,incomplete) incomplete_home={saved,snapshot,incomplete} end});pending()
expect(incomplete_home and incomplete_home[1] and incomplete_home[2].books==grouped_books
    and incomplete_home[2].archives==archives and incomplete_home[3],
    'home did not retain the complete snapshot on missing groups')
host.library_db.getShelfArchives=function() return nil end
local incomplete_new
host:refreshBookshelf(nil,{on_loaded=function(saved,snapshot,incomplete) incomplete_new={saved,snapshot,incomplete} end});pending()
expect(incomplete_new and not incomplete_new[1] and incomplete_new[2].groups_incomplete and incomplete_new[3]
    and incomplete_new[2].books[1].bookId=='new' and written_archives==previous_write,
    'first incomplete shelf was saved or discarded instead of being shown temporarily')
host.showInfo=original_info
host:applyShelfSnapshot(grouped_books,archives);host.shelf_group_key='archive:7'
host:showShelfView('books',nil,nil,{page=2})

host.client.get_shelf = function() return { books = grouped_books, archive = {} } end
shown[#shown].callbacks.on_refresh()
pending()
expect(shown[#shown].data.group_key == nil and shown[#shown].data.page == 1
        and #shown[#shown].data.books == 30, "deleted group did not fall back to all books")
host.runOnlineTask = function() return false end
shown[#shown].callbacks.on_refresh()
expect(not host.shelf_refreshing, "offline refresh stayed locked")
host.runOnlineTask = function(_self, _label, callback) callback() return true end
host.client.get_shelf = function() error("fixture") end
local before_failure = #shown
shown[#shown].callbacks.on_refresh()
expect(#shown == before_failure and not host.shelf_refreshing, "failed refresh replaced the shelf or stayed locked")
host.library_db.getShelf = function() return grouped_books end
host.library_db.getShelfArchives = function() return archives end
host:showBookshelf()
expect(#host.shelf_groups == 3, "cached opening lost archive data")
expect(#dialogs == 0, "current group cache triggered the upgrade hint")
host.library_db.getShelfArchives = function() return {} end
host:showBookshelf()
expect(#dialogs == 0, "synced shelf without groups triggered the upgrade hint")
host.library_db.getShelfArchives = function() return nil end
host:showBookshelf()
expect(#dialogs == 1 and shelf_settings.groups_refresh_hint_shown,
    "old shelf cache did not show and remember the one-time upgrade hint")
local hinted_view = host.shelf_view
local saved_refresh = host.refreshBookshelf
local refreshed_view
host.refreshBookshelf = function(_self, view) refreshed_view = view end
dialogs[1].ok_callback()
expect(refreshed_view == hinted_view, "upgrade hint did not refresh the visible shelf")
host.refreshBookshelf = saved_refresh
host:showBookshelf()
expect(#dialogs == 1, "old shelf cache repeated the upgrade hint before a refresh")
host.shelf_group_key = "archive:7"
host:onWeReadAccountChanged()
expect(host.shelf_groups == nil and host.shelf_group_key == nil, "account switch retained old groups")

host.runOnlineTask = function(_self, _label, callback) pending = callback return true end
local late_fetches, home_reopened = 0, false
host.client.get_shelf = function() late_fetches = late_fetches + 1 return { books = {} } end
host:refreshBookshelf(nil, { on_loaded = function() home_reopened = true end })
host:closeWeReadUI()
pending()
expect(late_fetches == 0 and not home_reopened and not host.shelf_refreshing,
    "leaving home before a queued refresh still fetched or reopened it")
local account = "first"
host.library_db.accountKey = function() return account end
host:refreshBookshelf(nil, { on_loaded = function() home_reopened = true end })
account = "second"
pending()
expect(late_fetches == 0 and not home_reopened and not host.shelf_refreshing,
    "queued home refresh crossed the account boundary")
local jobs, cancelled = {}, 0
host.client.shelf_authentication = function() return true end
host.isNetworkConnected = function() return true end
host.shelf_refresh_worker = {
    start = function(_self, task, callback) jobs[#jobs + 1] = { task = task, callback = callback } return true end,
    cancel = function() cancelled = cancelled + 1 end,
}
host:refreshBookshelf(nil, { on_loaded = function() home_reopened = true end })
local old_job = table.remove(jobs, 1)
host:closeWeReadUI()
host:refreshBookshelf(nil, { on_loaded = function() home_reopened = true end })
local fresh_context = host.shelf_refresh_context
old_job.callback(old_job.task())
expect(host.shelf_refresh_context == fresh_context and host.shelf_refreshing and late_fetches == 0,
    "late async shelf result canceled or fetched for a newer view")
local job = table.remove(jobs, 1)
job.callback(job.task())
expect(home_reopened and not host.shelf_refreshing and late_fetches == 1, "current async shelf could not complete")
home_reopened = false
host:refreshBookshelf(nil, { on_loaded = function() home_reopened = true end })
job = table.remove(jobs, 1)
account = "third"
job.callback(job.task())
expect(not home_reopened and late_fetches == 1 and not host.shelf_refreshing,
    "async shelf crossed an account boundary before HTTP")
host:refreshBookshelf(nil, { on_loaded = function() home_reopened = true end })
job = table.remove(jobs, 1)
local async_result = job.task()
shelf_settings.source = "native"
job.callback(async_result)
expect(not home_reopened and not host.shelf_refreshing, "result from prior source choice reopened shelf")
expect(cancelled > 0, "leaving shelf did not cancel native background worker")
shelf_settings.source = "auto"
host.showTransientInfo = function() end
local renewal_callback, renewal_starts, renewal_cancels = nil, 0, 0
host.native_renewal = {
    start = function(_self, _options, callback)
        renewal_starts = renewal_starts + 1
        renewal_callback = callback
        return true, { token = renewal_starts }
    end,
    cancel = function() renewal_cancels = renewal_cancels + 1 end,
}
host.client.get_shelf = function(_self, options)
    if options.recover_auth then error("shelf_source/native_expired", 0) end
    return { books = {}, archive = {}, _shelf_source = options.skip_native and "gateway" or "native" }
end
home_reopened = false
host:refreshBookshelf(nil, { on_loaded = function() home_reopened = true end })
job = table.remove(jobs, 1); job.callback(job.task())
expect(host.shelf_refreshing and renewal_starts == 1 and not home_reopened, "expired shelf did not wait for one renewal")
renewal_callback(true)
job = table.remove(jobs, 1); job.callback(job.task())
expect(home_reopened and not host.shelf_refreshing and host.shelf_active_source == "native", "successful renewal did not retry native shelf")
home_reopened = false
host:refreshBookshelf(nil, { on_loaded = function() home_reopened = true end })
job = table.remove(jobs, 1); job.callback(job.task()); renewal_callback(false)
job = table.remove(jobs, 1); job.callback(job.task())
expect(home_reopened and host.shelf_active_source == "gateway" and renewal_starts == 2, "failed renewal did not use one permitted fallback")
shelf_settings.source = "native"
home_reopened = false
host:refreshBookshelf(nil, { on_loaded = function() home_reopened = true end })
job = table.remove(jobs, 1); job.callback(job.task()); renewal_callback(false)
expect(not home_reopened and not host.shelf_refreshing and #jobs == 0, "native-only renewal failure bypassed source policy")
shelf_settings.source = "auto"
host:refreshBookshelf(nil, { on_loaded = function() home_reopened = true end })
job = table.remove(jobs, 1); job.callback(job.task())
local late_renewal = renewal_callback
host:closeWeReadUI()
late_renewal(true)
expect(renewal_cancels > 0 and not home_reopened and #jobs == 0, "cancelled renewal reopened closed shelf")
-- A dismissed shelf must not be revived by its still-queued group callback.
host:applyShelfSnapshot(grouped_books,archives)
host:showShelfView('books')
local replaced=host.shelf_view
host:showShelfView('books')
expect(closed_views[#closed_views]==replaced,'reopening the shelf left the old parent and its popup alive')
local stale_group=shown[#shown].callbacks.on_select_group
host:closeWeReadUI()
local before_stale=#shown
stale_group(nil)
expect(#shown==before_stale and not host.shelf_view,'a group callback revived a closed shelf')
local queued_actions={'on_select_group','on_page_changed','on_switch','on_display_change','on_search','on_refresh','on_sort','on_filter','on_select'}
for _change_index,change in ipairs({'account','epoch','session','document','snapshot','source','auth'}) do
    host.ui={};host.settings.get_auth_scope=nil
    shelf_settings.source='auto'
    host:applyShelfSnapshot(grouped_books,archives);host:showShelfView('books')
    local callbacks=shown[#shown].callbacks
    if change=='account' then account=account..'-new'
    elseif change=='epoch' then host.discovery_epoch=(host.discovery_epoch or 0)+1
    elseif change=='session' then host._reader_session_gen=(host._reader_session_gen or 0)+1
    elseif change=='document' then host.ui.document={file='/synthetic.epub'}
    elseif change=='snapshot' then host:applyShelfSnapshot(grouped_books,archives)
    elseif change=='source' then shelf_settings.source='native'
    else host.settings.get_auth_scope=function() return {vid='900000',epoch=2} end end
    local count=#shown
    for _action_index,name in ipairs(queued_actions) do callbacks[name](nil) end
    expect(#shown==count and host.shelf_group_key==nil,'stale shelf actions crossed '..change)
end
host.settings.get_auth_scope=nil
-- Search must not stop at a missing optional author or identifier field.
shelf_settings.source='auto';shelf_settings.view_mode='list';shelf_settings.sort_order='default'
host.library_db=nil;host._shelf_multi_loaded=nil;host.shelf_multi_groups={};host.shelf_group_key=nil
host.bookMatchesFilters=function(_self,book) return book.visible~=false end
local searchable={
    {bookId='ID-1049',title='Alpha',visible=true},
    {book_id='BK-2026',title='Beta',visible=true},
    {bookId=123987,title='Gamma',visible=true},
    {bookId='outside',title='Other',author='MiXeD Author',visible=true},
    {bookId='hidden',title='Hidden',author='MiXeD Author',visible=false},
}
host:applyShelfSnapshot(searchable,{{archiveId=7,name='Selected',bookIds={'ID-1049','BK-2026',123987}}})
host.shelf_group_key='archive:7'
for _,case in ipairs({{'1049','ID-1049'},{'bk-2026','BK-2026'},{'123987',123987}}) do
    host:showShelfView('books',case[1])
    local results=shown[#shown].data.books
    expect(#results==1 and (results[1].bookId or results[1].book_id)==case[2],
        'search lost an identifier following a missing optional field')
end
host.shelf_group_key=nil
host:showShelfView('books','mixed author')
expect(#shown[#shown].data.books==1 and shown[#shown].data.books[1].bookId=='outside',
    'search did not retain case-insensitive author matching and active filters')

-- Equal sort values must preserve shelf order across pages and pinned groups.
local tied,pinned,rest={},{},{}
for index=1,24 do
    local book={bookId=tostring(index),title='Same title',readUpdateTime=1700000000,isTop=index%7==0 and 1 or 0}
    tied[#tied+1]=book
    local bucket=book.isTop==1 and pinned or rest;bucket[#bucket+1]=book
end
local stable={};for _,book in ipairs(pinned) do stable[#stable+1]=book end
for _,book in ipairs(rest) do stable[#stable+1]=book end
host.shelf_regular=tied;host.shelf_groups={};host.shelf_group_key=nil;host.shelf_multi_groups={}
for _,order in ipairs({'time_desc','time_asc','name_asc','name_desc'}) do
    shelf_settings.sort_order=order
    for _=1,2 do
        host:showShelfView('books',nil,nil,{page=2})
        local result=shown[#shown].data.books
        expect(#result==#stable,'sort lost books')
        for index,book in ipairs(stable) do expect(result[index]==book,'equal sort changed shelf order for '..order) end
    end
end
for index,book in ipairs(tied) do expect(book.bookId==tostring(index),'sort changed the source shelf') end
local mixed={
    {bookId='a',title='A',readUpdateTime=40}, {bookId='b',title='B',readUpdateTime=10},
    {bookId='c',title='C',readUpdateTime=40}, {bookId='d',title='D'},
    {bookId='e',title='E',readUpdateTime='12'}, {bookId='f',title='F',readUpdateTime='bad'},
    {bookId='g',title='G',readUpdateTime=math.huge},
}
host.shelf_regular=mixed
for _,case in ipairs({{'time_desc',{'a','c','e','b','d','f','g'}},
                      {'time_asc',{'d','f','g','b','e','a','c'}}}) do
    shelf_settings.sort_order=case[1];host:showShelfView('books')
    for index,id in ipairs(case[2]) do
        expect(shown[#shown].data.books[index].bookId==id,'mixed time sort changed ordering or rejected an old value')
    end
end
print(("bookshelf_pagination_spec: %d checks"):format(checks))

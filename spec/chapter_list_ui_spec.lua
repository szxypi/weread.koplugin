-- Focused tests for paginated chapter actions and visible multi-selection state.

package.path = "./?.lua;" .. package.path

local function empty_module() return {} end
local catalog_view_data
local catalog_view_callbacks
package.preload["weread.ui.chapter_list_view"] = function()
    return {
        show = function(data, callbacks)
            catalog_view_data = data
            catalog_view_callbacks = callbacks
            return {position=data.browsing_position,browsingPosition=function(view) return view.position end,
                markChaptersCached=function(_,changed)
                for _,row in ipairs(data.chapters) do
                    if changed[row.source] then row.status='Cached' end
                end
                return true
            end}
        end,
    }
end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = empty_module
package.preload["ui/widget/buttondialog"] = function() return {new=function(_, options) return options end} end
package.preload["ui/widget/confirmbox"] = empty_module
package.preload["weread.lib.content"] = empty_module
package.preload["ui/widget/infomessage"] = empty_module
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(_, options)
        options.getInputText = function(self) return self.input end
        return options
    end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["ui/widget/progressbardialog"] = empty_module
package.preload["ui/widget/textviewer"] = empty_module
package.preload["weread.lib.protocol"] = empty_module

local closed = 0
local existing_files = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) callback() end,
        close = function() closed = closed + 1 end,
        show = function() end,
        nextTick = function(_self, callback) callback() end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function(path) return existing_files[path] == true end,
    }
end

G_reader_settings = {
    readSetting = function(_self, key)
        return key == "items_per_page" and 5 or nil
    end,
}

local Library = require("weread.ui.library")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local chapters = {}
for index = 1, 7 do
    chapters[index] = {
        chapterUid = index,
        title = "Chapter " .. tostring(index),
        wordCount = index * 100,
    }
end

local shown = {}
local fake_menu
local function choose(state,index)
    local item=state.items[index]
    if item.select_enabled~=false then state.options.on_choice(item) end
end
local downloaded_options, downloaded_targets
local returned_to_parent = false
local opened_chapter
local single_chapter_refresh
local host = {
    safeCallback = function(_self, _label, callback) return callback end,
    loadChapters = function(_self, _book, callback) callback(chapters) end,
    showList = function(_self, title, items, _empty, options)
        local state = { title = title, items = items, options = options }
        shown[#shown + 1] = state
        fake_menu = {
            item_group = {{},{}},
            getFocusItem = function(menu) return menu.item_group[2] end,
            getFirstVisibleItemIndex = function() return state.first_visible_item or 1 end,
            updateItems = function(_,focus,skip_layout)
                state.updates=(state.updates or 0)+1
                state.focus,state.skip_layout=focus,skip_layout
            end,
            switchItemTable = function(_menu, _title, next_items, number, _match, subtitle)
                state.items, state.subtitle, state.restore_item = next_items, subtitle, number
            end,
        }
        return fake_menu
    end,
    confirmAndDownloadChapters = function(_self, _book, targets, _suffix, options)
        downloaded_options = options
        downloaded_targets = targets
    end,
    showTransientInfo = function() end,
    openChapter = function(_self, _book, chapter, on_downloaded)
        opened_chapter = chapter
        single_chapter_refresh = on_downloaded
    end,
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

local persisted_books = {}
local book_reads = 0
host.settings = {
    get = function(_self, key, default)
        assert(key ~= "books", "catalog read the complete book collection")
        return default
    end,
    get_book = function(_self, id)
        assert(id == "book-1", "catalog read an unrelated book")
        book_reads = book_reads + 1
        return persisted_books[id]
    end,
}
local book = { bookId = "book-1", title = "Book", cached_chapters = {} }
host.library_db = {
    accountKey = function() return "synthetic-library" end,
    putBook = function() error("catalog display wrote unrelated book metadata") end,
}
local cancelled_view
package.loaded['weread.ui.catalog_request']={cancel=function(_,view) cancelled_view=view end}
host:showChapterList(book)
local original_view=host._chapter_list_view
original_view:onCloseWidget()
expect(cancelled_view==original_view,'closing chapter view immediately cancels its pending refresh')
original_view._catalog_closed=nil
expect(catalog_view_data.title == "Book" and #catalog_view_data.chapters == 7,
    "chapter catalog view receives the title and all chapters")
expect(catalog_view_data.chapters[1].status == "100 words",
    "chapter catalog preserves the right-side word-count status")
expect(type(catalog_view_callbacks.on_refresh) == "function"
    and type(catalog_view_callbacks.on_select_download) == "function",
    "chapter catalog keeps refresh and multi-download actions")
catalog_view_callbacks.on_select(chapters[1])
expect(opened_chapter == chapters[1], "chapter row opens the selected chapter")
expect(type(single_chapter_refresh) == "function",
    "chapter row passes a post-download refresh callback")
existing_files["/cache/chapter-1.epub"] = true
persisted_books["book-1"] = {cached_chapters={["1"]="/cache/chapter-1.epub"}}
single_chapter_refresh("/cache/chapter-1.epub", function(rebuild) rebuild() end)
expect(host._chapter_list_view==original_view and catalog_view_data.chapters[1].status=="Cached",
    "single download updates its status without reopening the catalog")

host:showChapterDownloadSelection(book, chapters, function()
    returned_to_parent = true
    host:showChapterList(book)
end)
local selection_menu = shown[1]
expect(selection_menu.items[1].text == "[Download] Selected chapters (0)",
    "selection page starts with a distinct download action")
expect(selection_menu.items[6].text == "[Download] Selected chapters (0)",
    "download action repeats at the top of the second page")
expect(selection_menu.items[1].select_enabled==false, "empty selection did not disable download")

choose(selection_menu,2)
expect(selection_menu.items[2].text:find("[✓]", 1, true) == 1,
    "selected chapter gets an explicit visible marker")
expect(selection_menu.items[2].mandatory == "Selected",
    "selected chapter gets a visible right-side status")
expect(selection_menu.items[1].text == "[Download] Selected chapters (1)",
    "download action count updates after selection")
expect(selection_menu.focus==2 and selection_menu.skip_layout,
    "another layout pass or a focus reset was requested when selecting a chapter")

choose(selection_menu,2)
expect(selection_menu.items[2].text:find("[  ]", 1, true) == 1,
    "tapping a selected chapter removes its marker")
expect(selection_menu.items[1].text == "[Download] Selected chapters (0)",
    "download action count decreases after deselection")
choose(selection_menu,2)

choose(selection_menu,1)
expect(downloaded_options and downloaded_options.separate_chapters == true,
    "multi-selection starts a separate-chapter download")
expect(downloaded_options.offer_read == nil,
    "multi-selection preserves the read-after-download prompt")
existing_files["/cache/chapter-1.epub"] = true
persisted_books["book-1"] = {
    cached_chapters = { ["1"] = "/cache/chapter-1.epub" },
}
downloaded_options.on_complete(true)
expect(closed == 1 and returned_to_parent,
    "successful multi-download closes selection and returns to parent list")
expect(catalog_view_data.chapters[1].status == "Cached",
    "successful multi-download refreshes cached chapter status")
expect(book_reads == 3, "opening and refreshing the catalog read one book each")

local batch_view=host._chapter_list_view
catalog_view_callbacks.on_select_download()
local batch_menu=shown[#shown]
choose(batch_menu,3)
choose(batch_menu,4)
choose(batch_menu,1)
existing_files['/cache/second.epub']=true
persisted_books['book-1'].cached_chapters['2']='/cache/second.epub'
persisted_books['book-1'].cached_chapters['3']='/cache/not-saved.epub'
downloaded_options.on_complete(true)
expect(host._chapter_list_view==batch_view and catalog_view_data.chapters[2].status=='Cached'
    and catalog_view_data.chapters[3].status=='300 words',
    'a partial batch updated only the saved chapter and kept the catalog open')

local claims=require('weread.lib.chapter_cache_claim')
local old_combined,old_usable=claims.combined,claims.usable
local proof={items={chapter_1=true,chapter_3=true}}
claims.combined=function(_,path) if path=='/cache/full.epub' then return proof end end
claims.usable=function(_,path) return path~='/cache/wrong.epub' end
host.getFullBookCachePath=function() return '/cache/full.epub' end
existing_files['/cache/full.epub']=true
existing_files['/cache/numeric.epub']=true
existing_files['/cache/wrong.epub']=true
local mappings={[2]='/cache/numeric.epub',['4']='/cache/missing.epub',['5']='/cache/wrong.epub'}
book.cached_chapters=mappings
persisted_books['book-1']={cached_chapters=mappings,cached_full_book='/cache/full.epub'}
host:showChapterList(book)
expect(catalog_view_data.chapters[1].status=='Cached' and catalog_view_data.chapters[3].status=='Cached',
    'combined-book chapters were not marked cached')
expect(catalog_view_data.chapters[2].status=='Cached','numeric single-chapter key was not marked cached')
expect(catalog_view_data.chapters[4].status=='400 words' and catalog_view_data.chapters[5].status=='500 words',
    'missing or unverified cache was shown as available')
expect(mappings['4']=='/cache/missing.epub','display removed the stale cache mapping')
host:showChapterDownloadSelection(book,chapters)
local status_menu=shown[#shown]
expect(status_menu.items[2].mandatory=='Cached' and status_menu.items[4].mandatory=='Cached',
    'combined-book status was missing from download selection')
expect(status_menu.items[3].mandatory=='Cached' and status_menu.items[5].mandatory=='400 words'
    and status_menu.items[7].mandatory=='500 words','download selection used incorrect cache status')
claims.combined,claims.usable=old_combined,old_usable
host.getFullBookCachePath=nil

local manager=require('ui/uimanager')
local old_schedule,late=manager.scheduleIn,nil
manager.scheduleIn=function(_,_,callback) late=callback end
local reopened=false
host:showChapterDownloadSelection(book,chapters,function() reopened=true end)
local stale_selection=shown[#shown]
choose(stale_selection,2)
choose(stale_selection,1)
downloaded_options.on_complete(true)
expect(type(late)=='function','completed selection did not schedule its return')
fake_menu:onCloseWidget();late()
expect(not reopened,'closed selection reopened its parent after a late completion')
manager.scheduleIn=old_schedule

local input
host.showInputDialog = function(_, widget) input = widget end
local chapter_loads = 0
host.loadChapters = function(_, _, callback, force_refresh, read_only_cache)
    assert(force_refresh == true or read_only_cache == true, "catalog browsing allowed cache writes")
    chapter_loads = chapter_loads + 1
    callback(chapters)
end
chapters[1].title = "Chapter Alpha"
chapters[4].title = "Chapter Alpha"
host:showChapterList(book)
local before_search={offset={x=0,y=480},x=1,y=5,focused=true}
host._chapter_list_view.position=before_search
catalog_view_callbacks.on_search()
input.input = "　ALPHA  chapter　"
input.buttons[1][2].callback()
local results = catalog_view_data.chapters
expect(chapter_loads == 1 and catalog_view_data.subtitle and #results == 2,
    "filter matches words without loading the catalog again")
expect(results[1].source == chapters[1] and results[2].source == chapters[4],
    "duplicate title results keep catalog order and chapter identity")
expect(results[1].title == "1. Chapter Alpha" and results[2].title == "4. Chapter Alpha",
    "duplicate title results are labeled by their original catalog index")
local filtered_view=host._chapter_list_view
catalog_view_callbacks.on_select(results[2].source)
expect(opened_chapter == chapters[4], "filtered selection opens the matching chapter")
existing_files['/cache/four.epub']=true
persisted_books['book-1'].cached_chapters['4']='/cache/four.epub'
single_chapter_refresh('/cache/four.epub',function(rebuild) rebuild() end)
expect(host._chapter_list_view==filtered_view and results[2].status=='Cached' and results[1].source==chapters[1],
    'a filtered download kept the view and updated the matching result')
catalog_view_callbacks.on_search()
input.buttons[1][1].callback()
expect(catalog_view_data.browsing_position==before_search and not catalog_view_data.subtitle,
    'clearing restored the browsing position of the full catalog')
catalog_view_callbacks.on_search()
input.input='Alpha'
input.buttons[1][2].callback()
catalog_view_callbacks.on_refresh()
expect(chapter_loads == 2 and #catalog_view_data.chapters == 2, "refresh preserves the active filter")
catalog_view_callbacks.on_search()
input.input = "missing chapter"
input.buttons[1][2].callback()
expect(catalog_view_data.empty_text == "No matching chapters.", "no matches have a visible message")
catalog_view_callbacks.on_search()
input.buttons[1][1].callback()
expect(not catalog_view_data.subtitle and #catalog_view_data.chapters == 7 and chapter_loads == 2,
    "clearing restores the catalog from memory")
expect(not catalog_view_data.browsing_position,'a refreshed catalog did not inherit an old row position')
expect(catalog_view_data.chapters[4].status=='Cached','clearing the filter kept the downloaded status')
catalog_view_callbacks.on_search()
local old_query = input
host._chapter_list_view:onCloseWidget()
old_query.input = "Alpha"
old_query.buttons[1][2].callback()
expect(not catalog_view_data.subtitle and #catalog_view_data.chapters == 7, "closed catalog rejects a queued search")

host:showChapterList(book)
catalog_view_callbacks.on_select_download()
local filtered_selection = shown[#shown]
expect(filtered_selection.options.left_icon == "appbar.search", "download selection has a search entry")
filtered_selection.first_visible_item=6
choose(filtered_selection,3)
local old_item = filtered_selection.items[4]
local function filter_selection(query)
    fake_menu:onLeftButtonTap()
    input.input = query
    input.buttons[1][2].callback()
end
filter_selection("　ALPHA chapter　")
expect(#filtered_selection.items == 4 and filtered_selection.items[3].text == "[  ] 1. Chapter Alpha"
    and filtered_selection.items[4].text == "[  ] 4. Chapter Alpha", "selection filter preserves duplicate positions")
filtered_selection.options.on_choice(old_item)
choose(filtered_selection,4)
expect(filtered_selection.items[1].text == "[Download] Selected chapters (2)", "hidden selection counts toward download")
filter_selection("not a chapter title")
expect(#filtered_selection.items == 2 and not filtered_selection.items[2].select_enabled
    and filtered_selection.items[2].text == "No matching chapters.", "empty selection filter has a visible message")
choose(filtered_selection,1)
expect(#downloaded_targets == 2 and downloaded_targets[1] == chapters[2] and downloaded_targets[2] == chapters[4],
    "filter downloads all selected chapters in original catalog order")
fake_menu:onLeftButtonTap()
input.buttons[1][1].callback()
expect(filtered_selection.subtitle == "" and filtered_selection.items[3].mandatory == "Selected"
    and filtered_selection.items[5].mandatory == "Selected" and filtered_selection.restore_item==6,
    "clearing the filter kept the selected chapters and original page")
filtered_selection.options.on_choice(old_item)
expect(filtered_selection.items[1].text=="[Download] Selected chapters (2)",
    "returning to the full list revived a stale chapter action")
fake_menu:onLeftButtonTap()
local old_selection_query = input
fake_menu:onCloseWidget()
old_selection_query.input = "Alpha"
old_selection_query.buttons[1][2].callback()
expect(not fake_menu._shelf_popup and filtered_selection.subtitle == "", "closing selection dismisses and invalidates its search")

chapters[2].title = "Introduction"
host:showChapterList(book)
catalog_view_callbacks.on_select_download()
local bulk = shown[#shown]
choose(bulk,3)
local old_download = bulk.items[1]
filter_selection("chapter")
expect(#bulk.items == 10 and bulk.items[7].text == "Matching chapters…",
    "matching chapter actions are reachable on a later page")
choose(bulk,7)
local options = assert(fake_menu._shelf_popup)
options.buttons[1][1].callback()
expect(bulk.items[1].text == "[Download] Selected chapters (7)"
    and bulk.items[10].text:find("[✓]",1,true)==1, "select matched every page and retained the hidden chapter")
local updates=bulk.updates
choose(bulk,7)
fake_menu._shelf_popup.buttons[1][1].callback()
expect(bulk.updates==updates, "selecting the same matches requested another page redraw")
local last_targets = downloaded_targets
bulk.options.on_choice(old_download)
expect(downloaded_targets == last_targets, "an old filter's download button started a different selection")
choose(bulk,1)
expect(#downloaded_targets == 7 and downloaded_targets[2] == chapters[2] and downloaded_targets[7] == chapters[7],
    "bulk download did not preserve original chapter order")
choose(bulk,2)
options = assert(fake_menu._shelf_popup)
options.buttons[2][1].callback()
choose(bulk,1)
expect(#downloaded_targets == 1 and downloaded_targets[1] == chapters[2],
    "deselecting matches removed a hidden selection")
choose(bulk,2)
options = assert(fake_menu._shelf_popup)
local old_tick, queued = manager.nextTick
manager.nextTick = function(_, callback) queued = callback end
options.buttons[1][1].callback()
fake_menu:onCloseWidget();queued()
manager.nextTick = old_tick
expect(bulk.items[1].text == "[Download] Selected chapters (1)", "a closed menu applied deferred bulk selection")

print(string.format(
    "chapter_list_ui_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)

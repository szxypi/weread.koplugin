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
            return {}
        end,
    }
end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = empty_module
package.preload["ui/widget/buttondialog"] = empty_module
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
local fake_menu = {
    updateItems = function() end,
    switchItemTable = function() end,
}
local downloaded_options
local returned_to_parent = false
local opened_chapter
local single_chapter_refresh
local host = {
    safeCallback = function(_self, _label, callback) return callback end,
    loadChapters = function(_self, _book, callback) callback(chapters) end,
    showList = function(_self, title, items, _empty, options)
        shown[#shown + 1] = { title = title, items = items, options = options }
        return fake_menu
    end,
    confirmAndDownloadChapters = function(_self, _book, _targets, _suffix, options)
        downloaded_options = options
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

host:showChapterDownloadSelection(book, chapters, function()
    returned_to_parent = true
    host:showChapterList(book)
end)
local selection_menu = shown[1]
expect(selection_menu.items[1].text_func() == "[Download] Selected chapters (0)",
    "selection page starts with a distinct download action")
expect(selection_menu.items[6].text_func() == "[Download] Selected chapters (0)",
    "download action repeats at the top of the second page")

selection_menu.items[2].callback()
expect(selection_menu.items[2].text_func():find("[✓]", 1, true) == 1,
    "selected chapter gets an explicit visible marker")
expect(selection_menu.items[2].mandatory_func() == "Selected",
    "selected chapter gets a visible right-side status")
expect(selection_menu.items[1].text_func() == "[Download] Selected chapters (1)",
    "download action count updates after selection")

selection_menu.items[2].callback()
expect(selection_menu.items[2].text_func():find("[  ]", 1, true) == 1,
    "tapping a selected chapter removes its marker")
expect(selection_menu.items[1].text_func() == "[Download] Selected chapters (0)",
    "download action count decreases after deselection")
selection_menu.items[2].callback()

selection_menu.items[1].callback()
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
expect(book_reads == 2, "opening and rebuilding the catalog read one book each")

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
expect(status_menu.items[2].mandatory_func()=='Cached' and status_menu.items[4].mandatory_func()=='Cached',
    'combined-book status was missing from download selection')
expect(status_menu.items[3].mandatory_func()=='Cached' and status_menu.items[5].mandatory_func()=='400 words'
    and status_menu.items[7].mandatory_func()=='500 words','download selection used incorrect cache status')
claims.combined,claims.usable=old_combined,old_usable
host.getFullBookCachePath=nil

local manager=require('ui/uimanager')
local old_schedule,late=manager.scheduleIn,nil
manager.scheduleIn=function(_,_,callback) late=callback end
local reopened=false
host:showChapterDownloadSelection(book,chapters,function() reopened=true end)
local stale_selection=shown[#shown]
stale_selection.items[2].callback()
stale_selection.items[1].callback()
downloaded_options.on_complete(true)
expect(type(late)=='function','completed selection did not schedule its return')
fake_menu:onCloseWidget();late()
expect(not reopened,'closed selection reopened its parent after a late completion')
manager.scheduleIn=old_schedule

local input
host.showInputDialog = function(_, widget) input = widget end
local chapter_loads = 0
host.loadChapters = function(_, _, callback)
    chapter_loads = chapter_loads + 1
    callback(chapters)
end
chapters[1].title = "Chapter Alpha"
chapters[4].title = "Chapter Alpha"
host:showChapterList(book)
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
catalog_view_callbacks.on_select(results[2].source)
expect(opened_chapter == chapters[4], "filtered selection opens the matching chapter")
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
catalog_view_callbacks.on_search()
local old_query = input
host._chapter_list_view:onCloseWidget()
old_query.input = "Alpha"
old_query.buttons[1][2].callback()
expect(not catalog_view_data.subtitle and #catalog_view_data.chapters == 7, "closed catalog rejects a queued search")

print(string.format(
    "chapter_list_ui_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)

-- Focused tests for opening the WeRead quick menu through a reader action.

package.path = "./?.lua;" .. package.path

local dialog_options, dialog_callbacks
local searched_book,searched_uid
local cached_book
package.preload['weread.ui.cached_book_search'] = function()
    return {open=function(_host,id) cached_book=id end}
end
package.preload['weread.ui.book_search'] = function()
    return {open=function(_host,id,_chapters,uid) searched_book,searched_uid=id,uid end}
end
package.preload["weread.ui.end_of_book_dialog"] = function()
    return { show = function(options, callbacks)
        dialog_options = options
        dialog_callbacks = callbacks
    end }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function(book_id) return book_id == "mp-book" end }
end

local Navigation = require("weread.ui.reader_navigation")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local shown_book_id
local notice
local host = {
    detectWeReadBook = function() return "book-1" end,
    showEndOfBookDialog = function(_self, book_id)
        shown_book_id = book_id
        return true
    end,
    showTransientInfo = function(_self, text, timeout)
        notice = { text = text, timeout = timeout }
    end,
}
for key, value in pairs(Navigation) do
    if host[key] == nil then host[key] = value end
end
local old_navigation=package.loaded['weread.ui.my_mark_navigation']
local cancellations=0
package.loaded['weread.ui.my_mark_navigation']={cancel_incoming=function(current)
    assert(current==host);cancellations=cancellations+1
end}

expect(host:onShowWeReadQuickMenu(), "quick menu opens for a WeRead document")
expect(shown_book_id == "book-1", "quick menu uses the detected WeRead book")

host.detectWeReadBook = function() return nil end
expect(host:onShowWeReadQuickMenu(),
    "quick menu opens for an unrelated local document")
expect(shown_book_id == nil,
    "quick menu keeps an empty WeRead context for a local document")

local bookshelf_opened = false
host.showBookshelf = function() bookshelf_opened = true end
expect(host:onShowWeReadBookshelf() and bookshelf_opened,
    "bookshelf gesture opens the WeRead bookshelf")

local local_bookshelf_opened, search_opened, action_stats_opened = false, false, false
host.showWereadCollection = function() local_bookshelf_opened = true end
host.showSearch = function() search_opened = true end
host.showReadStats = function() action_stats_opened = true end
expect(host:onShowWeReadLocalBookshelf() and local_bookshelf_opened,
    "local-bookshelf action opens the WeRead collection")
expect(host:onShowWeReadSearch() and search_opened,
    "search action opens WeRead search")
expect(host:onShowWeReadReadingStatistics() and action_stats_opened,
    "reading-statistics action opens WeRead statistics")
package.loaded['weread.ui.delayed_screenshot']={show=function(current) assert(current==host) end}
expect(host:onShowWeReadDelayedScreenshot() and cancellations==7,
    "all gesture actions cancel pending cross-chapter note navigation")
package.loaded['weread.ui.my_mark_navigation']=old_navigation

local stats_opened = false
local context_books = {}
local annotations_toggled = false
local native_searches = 0
local annotation_cache = { show_annotations = true }
local context_host = {
    ui = { document = { file = "/books/local.epub" },
        search = { onShowFulltextSearchInput = function() native_searches = native_searches + 1 end } },
    settings = {
        get = function(_self, key, default)
            if key == "books" then return context_books end
            if key == "cache" then return annotation_cache end
            return default
        end,
    },
    showTransientInfo = function(_self, text, timeout)
        notice = { text = text, timeout = timeout }
    end,
    showBookshelf = function() end,
    showSearch = function() end,
    showReadStats = function() stats_opened = true end,
    toggleAnnotationVisibility = function() annotations_toggled = true end,
    _annotationsVisibleForCurrentDocument = function() return false end,
}
for key, value in pairs(Navigation) do
    if context_host[key] == nil then context_host[key] = value end
end

expect(context_host:showEndOfBookDialog(nil),
    "global quick menu builds without a WeRead book")
expect(dialog_options.show_chapter_nav and dialog_options.show_next_chapter
        and dialog_options.enable_chapter_list == false
        and dialog_options.enable_next_chapter == false
        and dialog_options.enable_book_details == false
        and dialog_options.enable_sync_progress == false
        and dialog_options.enable_search_current == true
        and dialog_options.annotations_visible == true,
    "quick menu reflects the global annotation visibility preference")
expect(not dialog_callbacks.on_shelf_status,'unrelated document offered shelf status')
dialog_callbacks.on_search_current()
expect(native_searches == 1, "current file search uses KOReader's native search")
local progress_host,progress_options
package.loaded['weread.ui.reader_progress']={show=function(target,options) progress_host,progress_options=target,options end}
dialog_callbacks.on_reader_progress()
expect(progress_host==context_host and progress_options.native_chapters and not progress_options.single_chapter,
    'quick menu did not open local-file progress')
local typography_host
package.loaded['weread.ui.reader_typography']={show=function(target) typography_host=target end}
dialog_callbacks.on_reader_typography()
expect(typography_host==context_host,'quick menu did not open reading settings')
local stale_typography=dialog_callbacks.on_reader_typography
local stale_progress=dialog_callbacks.on_reader_progress
context_host.ui.document={file='/books/other.epub'};progress_host=nil;stale_progress()
expect(not progress_host, 'stale quick menu opened progress in another document')
typography_host=nil;stale_typography()
expect(not typography_host,'stale quick menu opened reading settings in another document')
context_host.ui.document={file='/books/local.epub'}

local original_document=context_host.ui.document
context_host.ui.document={file='/books/other.epub'}
dialog_callbacks.on_search_current()
expect(native_searches == 1, "a delayed search does not open on another document")
context_host.ui.document=original_document
original_document.file='/books/renamed.epub';dialog_callbacks.on_search_current()
expect(native_searches == 1, "a delayed search does not open after the source file changes")
original_document.file='/books/local.epub'
local original_search=context_host.ui.search
context_host.ui.search={};dialog_callbacks.on_search_current()
expect(native_searches == 1, "a delayed search does not use a replacement search module")
context_host.ui.search=original_search
local original_ui=context_host.ui
context_host.ui=nil;dialog_callbacks.on_search_current()
expect(native_searches == 1, "a delayed search does not open after reader closure")
context_host.ui=original_ui
context_host.ui.search=nil;context_host:showEndOfBookDialog(nil)
expect(dialog_options.enable_search_current==false, "missing native search is not offered as available")
context_host.ui.search=original_search;context_host:showEndOfBookDialog(nil)
annotation_cache.show_annotations = false
expect(context_host:showEndOfBookDialog(nil)
        and dialog_options.annotations_visible == false,
    "quick menu hides annotations when the global preference is disabled")
annotation_cache.show_annotations = true
dialog_callbacks.on_chapter_list()
expect(notice and notice.timeout == 1,
    "context-dependent action explains why it is unavailable")
dialog_callbacks.on_read_stats()
expect(stats_opened,
    "reading statistics remains available for local documents")
dialog_callbacks.on_toggle_annotations()
expect(annotations_toggled,
    "quick menu annotation button delegates to the shared visibility toggle")

context_books['123']={book_id='123',title='Synthetic'}
context_host.ensureChaptersLoaded=function() return {{chapterUid='1',title='First'}} end
context_host.getChapterInfoFromFile=function() return 1,nil,false end
expect(context_host:showEndOfBookDialog('123') and dialog_options.enable_search_book==true
        and dialog_options.enable_search_cached==true,
    'numeric WeRead book enables whole-book search')
dialog_callbacks.on_search_cached()
expect(cached_book=='123','downloaded search opens for the current book')
cached_book=nil;local cached_doc=context_host.ui.document;context_host.ui.document={file='/other.epub'}
dialog_callbacks.on_search_cached();context_host.ui.document=cached_doc
expect(cached_book==nil,'delayed downloaded search ignores a changed document')
context_host._reader_session_gen=1;dialog_callbacks.on_search_cached();context_host._reader_session_gen=nil
expect(cached_book==nil,'delayed downloaded search ignores a changed reader session')
dialog_callbacks.on_search_book()
expect(searched_book=='123','whole-book search opens for the current book')
searched_book=nil;local old_doc=context_host.ui.document;context_host.ui.document={file='/other.epub'}
dialog_callbacks.on_search_book();context_host.ui.document=old_doc
expect(searched_book==nil,'delayed whole-book search ignores a changed document')
context_host._reader_session_gen=1;dialog_callbacks.on_search_book();context_host._reader_session_gen=nil
expect(searched_book==nil,'delayed whole-book search ignores a changed reader session')
local auth_epoch=1
context_host.settings.get_auth_scope=function() return {vid='123',epoch=auth_epoch} end
context_host.settings.auth_scope_matches=function(_self,scope) return scope.epoch==auth_epoch end
local active_id,account,status_opened='123','owner'
context_host.library_db={accountKey=function() return account end}
context_host.detectWeReadBook=function() return active_id end
context_host.showShelfState=function(_self,id) status_opened=id end
context_host:showEndOfBookDialog('123')
local status=dialog_callbacks.on_shelf_status
expect(type(status)=='function','signed-in reader did not offer shelf status')
status();expect(status_opened=='123','reader status did not target the active book')
status_opened=nil;active_id='124';status()
expect(status_opened==nil,'reader status followed a changed file-to-book association')
active_id='123';account='other';status()
expect(status_opened==nil,'reader status reused an old account')
account='owner';context_host._weread_suspended=true;status()
expect(status_opened==nil,'suspended reader opened shelf status')
context_host._weread_suspended=false;auth_epoch=2
status();expect(status_opened==nil,'reader status reused a previous login')
dialog_callbacks.on_search_book()
expect(searched_book==nil,'delayed whole-book search ignores a changed account session')
dialog_callbacks.on_search_cached()
expect(cached_book==nil,'delayed downloaded search ignores a changed account session')
context_host.settings.get_auth_scope=nil;context_host.settings.auth_scope_matches=nil

context_host.source_position={current=function() error('numeric search must not inspect source position') end}
context_host:showEndOfBookDialog('123');dialog_callbacks.on_search_book()
expect(searched_book=='123' and searched_uid==nil,'numeric search unexpectedly inspected the CB fallback position')
context_books['CB_Synthetic']={book_id='CB_Synthetic',title='Synthetic'}
context_host.ensureChaptersLoaded=function() return {{chapterUid='1'},{chapterUid='2'},{chapterUid='3'}} end
context_host.getChapterInfoFromFile=function() return 2,{chapterUid='2'},false end
context_host.source_position.current=function() return {book_id='CB_Synthetic',chapter_uid='3'} end
context_host:showEndOfBookDialog('CB_Synthetic');dialog_callbacks.on_search_book()
expect(searched_book=='CB_Synthetic' and searched_uid=='3','live CB source chapter was not passed to search')
expect(not dialog_callbacks.on_shelf_status,'signed-out reader offered account status')
context_host.settings.get_auth_scope=function() return {vid='123',epoch=auth_epoch} end
context_host.settings.auth_scope_matches=function(_self,scope) return scope.epoch==auth_epoch end
active_id='CB_Synthetic';context_host:showEndOfBookDialog(active_id);dialog_callbacks.on_shelf_status()
expect(status_opened==active_id,'imported book could not open its verified shelf status')
dialog_callbacks.on_search_cached()
expect(cached_book=='CB_Synthetic','downloaded search did not support an imported book')
context_host.source_position.current=function() return {book_id='CB_Foreign',chapter_uid='3'} end
context_host:showEndOfBookDialog('CB_Synthetic');dialog_callbacks.on_search_book()
expect(searched_uid=='2','foreign source position replaced the current file chapter')
context_host.source_position.current=function() error('source temporarily unavailable') end
context_host:showEndOfBookDialog('CB_Synthetic');dialog_callbacks.on_search_book()
expect(searched_uid=='2','unavailable source position discarded the current file chapter')
context_host.getChapterInfoFromFile=function() return nil,nil,false end
context_books['CB_Synthetic'].cached_chapters={['2']='/books/local.epub'}
context_host:showEndOfBookDialog('CB_Synthetic');dialog_callbacks.on_search_book()
expect(searched_uid=='2','a uniquely mapped chapter was lost when the catalog was not attached')
context_books['CB_Synthetic'].cached_chapters['3']='/books/local.epub'
context_host:showEndOfBookDialog('CB_Synthetic');dialog_callbacks.on_search_book()
expect(searched_uid==nil,'an ambiguous cached file was treated as one chapter')
context_books['CB_Synthetic'].cached_chapters['3']=nil
context_books['CB_Synthetic'].cached_full_book='/books/local.epub'
context_host:showEndOfBookDialog('CB_Synthetic');dialog_callbacks.on_search_book()
expect(searched_uid==nil,'a full-book file was treated as one chapter')
context_host.source_position=nil

context_books["mp-book"] = { book_id = "mp-book", title = "Article" }
context_host.ensureChaptersLoaded = function()
    error("public account quick menu must not load regular book chapters")
end
expect(context_host:showEndOfBookDialog("mp-book"),
    "quick menu opens for a public account article")
expect(dialog_options.enable_book_details == true
        and dialog_options.enable_chapter_list == false
        and dialog_options.enable_next_chapter == false
        and dialog_options.enable_sync_progress == false and dialog_options.enable_search_book == false,
    "public account articles only enable supported contextual actions")
expect(not dialog_callbacks.on_shelf_status,'public account article offered book shelf status')
notice = nil
dialog_callbacks.on_sync_progress()
expect(notice and notice.timeout == 1,
    "public account article explains that progress sync needs a regular book")

print(string.format(
    "reader_quick_menu_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)

package.path = "./?.lua;" .. package.path

local existing_paths = {}
local catalog_save_count = 0
local function empty_module() return {} end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = empty_module
package.preload["ui/widget/buttondialog"] = empty_module
package.preload["ui/widget/confirmbox"] = empty_module
package.preload["ui/widget/infomessage"] = empty_module
package.preload["ui/widget/inputdialog"] = empty_module
package.preload["ui/widget/progressbardialog"] = empty_module
package.preload["ui/widget/textviewer"] = empty_module
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_self, _delay, callback) callback() end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...) local values={...};return (text:gsub('%%(%d+)',function(index) return tostring(values[tonumber(index)] or '') end)) end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function(path) return existing_paths[path] == true end,
    }
end

local fetched_chapters = { { chapterUid = 7, title = "Cached chapter" } }
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = function() end,
        fetch_catalog = function() return fetched_chapters end,
        catalog_cache_path = function() return "/cache/42/catalog.json" end,
        save_catalog_cache = function()
            catalog_save_count = catalog_save_count + 1
            return true
        end,
        load_catalog_cache = function() return nil end,
    }
end

local Library = require("weread.ui.library")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local books = {}
local db_detail
local written_book
local written_chapters
local db_chapters
local auto_refresh
local shown_book
local opened_path
local single_download_options
local single_download_refreshed = false
local host = {
    settings = {
        get = function(_self, key, default)
            if key == "books" then return books end
            if key == 'account' then return {user_vid='raw-owner-id'} end
            return default
        end,
        set = function(_self, key, value)
            if key == "books" then books = value end
        end,
        flush = function() end,
    },
    library_db = {
        accountKey = function() return "account-a" end,
        getBook = function() return db_detail end,
        putBook = function(_self, book) written_book = book return true end,
        getChapters = function() return db_chapters end,
        putChapters = function(_self, _book_id, chapters)
            written_chapters = chapters
            return true
        end,
    },
    refreshBookRecord = function(_self, book, _old, options)
        auto_refresh = options and options.automatic and book
    end,
    showBookMenu = function(_self, book) shown_book = book end,
    getFullBookCachePath = function(_self, book) return book.full_path end,
    openFile = function(_self, path) opened_path = path end,
    confirmAndDownloadChapters = function(_self, _book, _chapters, _suffix, options)
        single_download_options = options
    end,
    showInfo = function() end,
    requireLogin = function() return true end,
    runOnlineTask = function(_self, _label, callback) callback() return true end,
    showBusy = function() end,
    closeBusy = function() end,
    client = {},
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

host:showBookRecord({ bookId = "42", title = "First open" })
expect(auto_refresh and auto_refresh.book_id == "42",
    "first open without a detail snapshot did not auto-refresh")
expect(written_book and written_book.title == "First open",
    "first-open basic metadata was not written to SQLite")

auto_refresh, shown_book = nil, nil
db_detail = { book_id = "42", title = "Cached", detail_updated_at = 123 }
host:showBookRecord({ bookId = "42", title = "Shelf title" })
expect(shown_book and not auto_refresh,
    "cached detail unexpectedly triggered an automatic refresh")

local callback_chapters
host:loadChapters({ book_id = "42", title = "Catalog" }, function(chapters)
    callback_chapters = chapters
end, true)
expect(written_chapters == fetched_chapters,
    "fetched chapter catalog was not written to SQLite")
expect(callback_chapters == fetched_chapters,
    "chapter callback did not receive the fetched catalog")

db_chapters = { { chapterUid = 8, title = "Database chapter" } }
callback_chapters = nil
local db_book = { book_id = "42", title = "Database catalog" }
host:loadChapters(db_book, function(chapters)
    callback_chapters = chapters
end)
expect(callback_chapters == db_chapters and db_book.chapters == db_chapters,
    "SQLite chapter hit was not returned")
expect(catalog_save_count == 2,
    "SQLite chapter hit did not backfill missing catalog.json")

local partial = {
    book_id = "42",
    chapter_uid = 3,
    chapters = {
        { chapterUid = 1 }, { chapterUid = 2 }, { chapterUid = 3 },
        { chapterUid = 4 }, { chapterUid = 5 },
    },
    cached_chapters = { ["2"] = "/cache/2.epub", ["4"] = "/cache/4.epub" },
}
existing_paths["/cache/2.epub"] = true
existing_paths["/cache/4.epub"] = true
host:openBookForReading(partial)
expect(opened_path == "/cache/2.epub",
    "equal-distance cached chapter did not prefer the preceding chapter")

partial.chapter_uid = 4
host:openBookForReading(partial)
expect(opened_path == "/cache/4.epub",
    "exact cached progress chapter was not selected")

partial.pending_upload_account='account-a'
partial.pending_upload_position={book_id='42',chapter_uid=2,percent=25}
host:openBookForReading(partial)
expect(opened_path=='/cache/2.epub','cached Read ignored pending local chapter and opened newer remote metadata')
partial.pending_upload_account='other-account'
host:openBookForReading(partial)
expect(opened_path=='/cache/4.epub','cached Read used a different account pending chapter')
partial.pending_upload_account='account-a'
partial.pending_upload_position.book_id='other-book'
host:openBookForReading(partial)
expect(opened_path=='/cache/4.epub','cached Read used a different book pending chapter')
partial.pending_upload_position=nil
partial.recent_read_account='account-a'
partial.last_local_position={book_id='42',chapter_uid=2,percent=25}
host:openBookForReading(partial)
expect(opened_path=='/cache/2.epub','cached Read ignored the last native reading chapter')
partial.recent_read_account='other-account'
host:openBookForReading(partial)
expect(opened_path=='/cache/4.epub','cached Read used a different account last local chapter')
partial.last_local_position=nil
local original_catalog=partial.chapters
partial.chapters={}
partial.chapter_uid=2
partial.pending_upload_position={book_id='42',chapter_uid=4}
partial.pending_upload_account='account-a'
host:openBookForReading(partial)
expect(opened_path=='/cache/4.epub','missing catalog ignored a directly cached local chapter UID')
partial.pending_upload_account='other-account'
host:openBookForReading(partial)
expect(opened_path=='/cache/2.epub','missing catalog used a foreign pending chapter')
partial.chapters=original_catalog
partial.pending_upload_position=nil

partial.full_path = "/cache/full.epub"
existing_paths[partial.full_path] = true
host:openBookForReading(partial)
expect(opened_path == partial.full_path,
    "complete cached book did not take priority over chapter caches")

host:downloadChapterAndRead(partial, partial.chapters[3], function()
    single_download_refreshed = true
end)
expect(single_download_options and single_download_options.single_chapter == true,
    "single chapter download keeps single-chapter mode")
single_download_options.on_complete(true, "/cache/3.epub")
expect(single_download_refreshed,
    "single chapter completion did not notify the chapter list")

db_detail,auto_refresh,shown_book=nil,nil,nil
books['43']={book_id='43',progress=84,cached_chapters={['1']='/kept.epub'},pending_upload_position={percent=84}}
host:showBookRecord({bookId='43',title='Imported metadata',detail_updated_at=123},{verified_metadata=true})
expect(shown_book and not auto_refresh and shown_book.progress==84 and shown_book.cached_chapters['1']=='/kept.epub'
    and shown_book.pending_upload_position.percent==84,'verified import refreshed twice or replaced current local state')

-- A stale open details menu and legacy SQLite row can both outlive a completed
-- upload. Neither is allowed to resurrect its cleared pending checkpoint.
local reading_fields = {
    'app_id','chapter_idx','chapter_offset','chapter_uid','last_local_position','last_pull_at',
    'last_remote_position','last_sync_error','last_upload_at','last_uploaded_position','pclts',
    'pending_upload_position','pending_upload_reason','pending_upload_account','source_dispatch',
    'progress','psvts','read_context_updated_at','read_session_entered_at','read_session_id',
    'reader_url','summary','token','verified_at','verified_source',
}
local stale = { bookId='44', title='Updated metadata', detail_updated_at=123, cache_dir='/cache/44' }
for _i, key in ipairs(reading_fields) do stale[key] = { stale=true } end
db_detail = stale
books['44'] = { book_id='44', last_uploaded_position={chapter_uid=7,chapter_offset=200} }
host:showBookRecord({bookId='44',title='Fresh title'})
expect(books['44'].title=='Fresh title' and books['44'].cache_dir=='/cache/44', 'metadata/cache paths stopped merging')
for _i, key in ipairs(reading_fields) do
    expect(key=='last_uploaded_position' and books['44'][key].chapter_offset==200 or key~='last_uploaded_position' and books['44'][key]==nil,
        'legacy detail resurrected cleared reading field: '..key)
end
local pending = { chapter_uid=8,chapter_offset=300 }
books['44'].pending_upload_position = pending
books['44'].pending_upload_account = 'account-a'
host:showBookRecord(stale)
expect(books['44'].pending_upload_position==pending and books['44'].pending_upload_account=='account-a'
    and books['44'].last_uploaded_position.chapter_offset==200, 'stale incoming menu replaced current checkpoint')
expect(books['44'].title=='Updated metadata' and stale.pending_upload_position.stale, 'metadata merge mutated caller or lost title')
db_detail = nil

local catalog_book,catalog_cancelled
package.preload['weread.ui.mp_catalog']=function() return {
    start=function(self,book) expect(self==host,'MP catalog host changed');catalog_book=book;return true end,
    cancel=function(self) expect(self==host,'MP catalog cancel host changed');catalog_cancelled=true end}
end
local mp_book={book_id='MP_WXS_900001',title='Synthetic account'}
expect(host:fetchMPArticles(mp_book) and catalog_book==mp_book,'MP catalog did not delegate to native coordinator')
host:cancelMPArticleCatalog();expect(catalog_cancelled,'MP catalog cancellation not delegated')

local preparation
require('weread.ui.book_reading').start=function(_self, selected, view)
    preparation = { book = selected, view = view }; return true
end
host.settings.get_book = function(_self, id) return books[id] end
books["42"] = partial
opened_path = nil
expect(host:startBookReading(partial) and opened_path == partial.full_path and not preparation,
    "cached Read did not keep the offline/native path")
local view = {}; host._book_detail_view = view
expect(not host:startBookReading(partial, {}) and not preparation, "stale detail triggered a read")
local uncached = { book_id = "99", title = "Uncached" }
books["99"] = uncached
db_chapters = nil
expect(host:startBookReading({ book_id = "99", title = "Stale" }, view)
    and preparation.book == uncached and preparation.view == view, "uncached Read did not prepare the latest record")
local detail_data
package.preload['weread.ui.book_detail_view']=function() return {show=function(data) detail_data=data;return {} end} end
local detail_book={book_id='42',title='Synthetic book',chapters={{chapterUid=1},{chapterUid=2},{chapterUid=3}},
    cached_chapters={['1']='/cache/1.epub',['2']='/cache/2.epub',['unknown']='/cache/unknown.epub'}}
existing_paths['/cache/1.epub']=true;existing_paths['/cache/2.epub']=true;existing_paths['/cache/unknown.epub']=true
books['42']=detail_book
detail_book.full_path='/cache/full.epub';existing_paths[detail_book.full_path]=true
host.bookRecordHasDownload=function() return true end
host.safeCallback=function(_self,_title,callback) return callback end
Library.showBookMenu(host,detail_book)
expect(detail_data.status_line=='Full book cached','full download with separate chapters displayed a partial count')
detail_book.chapters=nil;Library.showBookMenu(host,detail_book)
expect(detail_data.status_line=='Full book cached','full download without a catalog displayed a partial count')
detail_book.full_path=nil;detail_book.chapters={{chapterUid=1},{chapterUid=2},{chapterUid=3}}
Library.showBookMenu(host,detail_book)
expect(detail_data.status_line=='Cached 2/3 chapters','partial download lost the count status')
print(("library_cache_flow_spec: %d checks"):format(checks))

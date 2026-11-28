package.path = "./?.lua;" .. package.path

local existing_paths = {}
local path_probes = {}
local catalog_save_count = 0
local catalog_target
local last_dialog
local function empty_module() return {} end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = empty_module
package.preload["ui/widget/buttondialog"] = empty_module
package.preload["ui/widget/confirmbox"] = function() return {new=function(_self,value) return value end} end
package.preload["ui/widget/infomessage"] = empty_module
package.preload["ui/widget/inputdialog"] = empty_module
package.preload["ui/widget/progressbardialog"] = empty_module
package.preload["ui/widget/textviewer"] = empty_module
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_self, _delay, callback) callback() end,
        show=function(_self,dialog) last_dialog=dialog end,
        close=function(_self,dialog) if dialog.onCloseWidget then dialog:onCloseWidget() end end,
        nextTick=function(_self,callback) callback() end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end,utf8_substr=dofile('weread/lib/protocol.lua').utf8_substr }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...) local values={...};return (text:gsub('%%(%d+)',function(index) return tostring(values[tonumber(index)] or '') end)) end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function(path)
            if type(path)=='string' then path_probes[path]=(path_probes[path] or 0)+1 end
            return existing_paths[path] == true
        end,
    }
end

local fetched_chapters = { { chapterUid = 7, title = "Cached chapter" } }
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = function() end,
        fetch_catalog = function() return fetched_chapters end,
        catalog_cache_path = function() return "/cache/42/catalog.json" end,
        save_catalog_cache = function(_client, _settings, book)
            catalog_save_count = catalog_save_count + 1
            catalog_target = book
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
local current_owner='account-a'
local prefer_eink=false
local catalog_registrations=0
local host = {
    settings = {
        get = function(_self, key, default)
            if key == "books" then return books end
            if key == 'account' then return {user_vid='raw-owner-id'} end
            if key == 'prefer_eink_chapters' then return prefer_eink end
            return default
        end,
        set = function(_self, key, value)
            if key == "books" then books = value end
        end,
        get_book_indexes = function() return books end,
        get_book = function(_self, id)
            return require('weread.lib.read_access').cached_key(books,id)
        end,
        remember_catalog_book = function(_self, id, book)
            catalog_registrations = catalog_registrations + 1
            if books[id] then books[id].chapters = nil
            else
                books[id] = {book_id=id,title=book.title,cache_dir=book.cache_dir}
            end
            return true
        end,
        flush = function() end,
    },
    library_db = {
        accountKey = function() return current_owner end,
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

local notices={}
host.showInfo=function(_,message) notices[#notices+1]=message end
local conflict={book_id='wrong',cached_file='/cache/foreign.epub'}
books['47']=conflict
host:showBookRecord({bookId='47',title='Requested'})
expect(books['47']==conflict and conflict.book_id=='wrong' and not written_book and #notices==1,
    'opening details rewrote a conflicting saved book')
Library.showBookMenu(host,{bookId='47',title='Requested'})
expect(books['47']==conflict and conflict.book_id=='wrong' and #notices==2,
    'opening a menu accepted a conflicting saved book')
books['47']=nil
host:showBookRecord({bookId='47',book_id='48'})
expect(#notices==3 and not written_book,'conflicting incoming identifiers were accepted')
local legacy={book_id='49',title='Old',cached_file='/cache/legacy.epub'}
books[49]=legacy
host:showBookRecord({bookId='49',title='New'})
expect(books['49']==legacy and books[49]==nil and legacy.cached_file=='/cache/legacy.epub',
    'opening a safe legacy numeric key lost the book or kept duplicate indices')
local duplicate_one={book_id='50',title='String'};local duplicate_two={book_id='50',title='Numeric'}
books['50'],books[50]=duplicate_one,duplicate_two
local old_written=written_book
host:showBookRecord({bookId='50',title='Requested'})
expect(books['50']==duplicate_one and books[50]==duplicate_two and written_book==old_written and #notices==4,
    'opening duplicate indices changed an ambiguous saved book')
books['49'],books['50'],books[50]=nil,nil,nil
written_book=nil

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

db_detail,auto_refresh,shown_book=nil,nil,nil
books['44']={book_id='44',_library_account_key=current_owner,detail_updated_at=123,detail_source='native',intro='Saved introduction'}
host:showBookRecord({bookId='44',title='Saved'})
expect(shown_book and shown_book.intro=='Saved introduction' and not auto_refresh,
    'same-account saved details waited for metadata when SQLite lacked a copy')
current_owner='account-b';auto_refresh,shown_book=nil,nil
host:showBookRecord({bookId='44',title='Other account'})
expect(auto_refresh and not auto_refresh.intro and not shown_book,'foreign saved details bypassed the metadata refresh')
current_owner='account-a'

db_detail,auto_refresh,shown_book=nil,nil,nil
host:showBookRecord({bookId='45',title='Public book',_public_info={intro='Public excerpt',
    publisher='Public publisher',newRating=860,newRatingCount=12,token='secret'}})
expect(auto_refresh and auto_refresh.intro=='Public excerpt' and auto_refresh.publisher=='Public publisher'
    and auto_refresh.newRating==860 and auto_refresh.newRatingCount==12 and not auto_refresh._public_info
    and not auto_refresh.token,'public metadata was not safely applied to a new record')
expect(not books['45'].intro and not books['45'].publisher and not books['45']._public_info
    and not written_book.intro,'public excerpt was saved as verified book metadata')
db_detail=written_book;auto_refresh=nil
host:showBookRecord({bookId='45',title='Public book'})
expect(auto_refresh~=nil,'a previous public excerpt suppressed full metadata refresh')
books['46']={book_id='46',intro='Full existing introduction',publisher='Verified publisher',
    newRating=900,newRatingCount=99,progress=75}
db_detail={book_id='46',detail_updated_at=123}
host:showBookRecord({bookId='46',title='Public',_public_info={intro='Shorter excerpt',publisher='Other',
    newRating=500,newRatingCount=1}})
expect(shown_book and shown_book.intro=='Full existing introduction' and shown_book.publisher=='Verified publisher'
    and shown_book.newRating==900 and shown_book.newRatingCount==99 and shown_book.progress==75,
    'public excerpt overwrote richer saved details or reading state')
db_detail=nil

local callback_chapters
package.loaded['weread.ui.catalog_request']={start=function(target,book,done)
    local ok,value=pcall(function()
        require('weread.lib.content').ensure_reader_state(target.client,book)
        return require('weread.lib.content').fetch_catalog(target.client,book)
    end)
    if ok then done(value)
    else target:showInfo(value=='download_read/rate_limited'
        and 'WeRead is limiting requests. Download stopped. Please try again later.' or 'catalog failed') end
end,cancel=function() end}
host:loadChapters({ book_id = "42", title = "Catalog" }, function(chapters)
    callback_chapters = chapters
end, true)
expect(written_chapters == fetched_chapters,
    "fetched chapter catalog was not written to SQLite")
expect(callback_chapters == fetched_chapters,
    "chapter callback did not receive the fetched catalog")

do
    local registration_count=catalog_registrations
    local initial_writes=catalog_save_count
    local prior_request=package.loaded['weread.ui.catalog_request']
    local latest={book_id='61',cache_dir='/cache/current',cached_chapters={['7']='/cache/current/chapter.epub'},
        pending_upload_position={chapter_uid='7',chapter_offset=71}}
    local old={book_id='61',cache_dir='/cache/old'}
    books['61']={book_id='61',cache_dir='/cache/old'}
    local queued,displayed
    package.loaded['weread.ui.catalog_request']={start=function(_,_,done) queued=done end,cancel=function() end}
    local get,set=host.settings.get,host.settings.set
    host.settings.get=function(self,key,default)
        assert(key~='books','catalog refresh hydrated the whole library')
        return get(self,key,default)
    end
    host.settings.set=function() error('catalog refresh saved the whole library') end
    local prior_details=written_book
    host:loadChapters(old,function(value) displayed=value end,true)
    books['61']=latest
    assert(queued)(fetched_chapters)
    expect(displayed==fetched_chapters and catalog_target==latest and old.cache_dir==latest.cache_dir,
        'catalog refresh used the changed cached book directory')
    expect(books['61']==latest and latest.pending_upload_position.chapter_offset==71 and latest.cached_chapters['7']
        and written_book==prior_details and catalog_registrations==registration_count,
        'catalog refresh saved stale metadata or lost concurrent download or progress')

    local prior_writes=catalog_save_count
    books[61]={book_id='61',cache_dir='/cache/duplicate'}
    queued(fetched_chapters)
    expect(catalog_save_count==prior_writes and catalog_registrations==registration_count,
        'ambiguous legacy index allowed a catalog write')
    books[61]=nil
    latest.chapters={{chapterUid=3}}
    local save= require('weread.lib.content').save_catalog_cache
    require('weread.lib.content').save_catalog_cache=function() return false,'synthetic failure' end
    queued(fetched_chapters)
    expect(latest.chapters and catalog_registrations==registration_count,
        'a failed catalog file save retired the only inline catalog')
    require('weread.lib.content').save_catalog_cache=save
    queued(fetched_chapters)
    expect(not latest.chapters and catalog_registrations==registration_count+1,
        'a successful save did not retire the superseded inline catalog')
    catalog_save_count=initial_writes
    books['61']=nil
    host.settings.get,host.settings.set=get,set
    package.loaded['weread.ui.catalog_request']=prior_request
end

local content=require("weread.lib.content")
local previous_reader,previous_info=content.ensure_reader_state,host.showInfo
local rate_notice,unexpected_callback
content.ensure_reader_state=function() error("download_read/rate_limited",0) end
host.showInfo=function(_,text) rate_notice=text end
host:loadChapters({book_id="42"},function() unexpected_callback=true end,true)
expect(rate_notice=="WeRead is limiting requests. Download stopped. Please try again later."
    and not unexpected_callback and written_chapters==fetched_chapters,
    "rate-limited chapter catalog exposed an internal error or changed saved chapters")
content.ensure_reader_state,host.showInfo=previous_reader,previous_info

local delayed,old_online,old_writes=nil,host.runOnlineTask,catalog_save_count
host.runOnlineTask=function(_,_,fn) delayed=fn;return true end
local changing_book={book_id='42'}
unexpected_callback=false
host:loadChapters(changing_book,function() unexpected_callback=true end,true)
changing_book.book_id='43';assert(delayed);delayed()
expect(not unexpected_callback and catalog_save_count==old_writes,'deferred catalog request used a replaced book')
host.runOnlineTask=old_online

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

do
    local json_chapters = { { chapterUid = 9, title = "File chapter" } }
    local load_file, chapter_writes = content.load_catalog_cache, written_chapters
    local saved_count, probes = catalog_save_count, path_probes["/cache/42/catalog.json"]
    content.load_catalog_cache = function() return json_chapters end
    for index, expected in ipairs({fetched_chapters, db_chapters, json_chapters}) do
        if index == 3 then db_chapters = nil end
        local displayed = { book_id = "42", chapters = index == 1 and expected or nil }
        host:loadChapters(displayed, function(chapters)
            callback_chapters = chapters
        end, false, true)
        expect(callback_chapters == expected and displayed.chapters == expected,
            "read-only catalog did not use the available local source")
    end
    expect(written_chapters == chapter_writes and catalog_save_count == saved_count
        and path_probes["/cache/42/catalog.json"] == probes,
        "browsing the local catalog tried to persist or check its redundant copy")

    content.load_catalog_cache = load_file
    host:loadChapters({ book_id = "42" }, function(chapters)
        callback_chapters = chapters
    end, false, true)
    expect(callback_chapters == fetched_chapters and written_chapters == fetched_chapters
        and catalog_save_count == saved_count + 1,
        "opening a catalog without local chapters did not fetch and save it")
end

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

do
    local many={book_id='74',chapter_uid=37,chapters={},cached_chapters={}}
    for index=1,80 do
        local uid=tostring(index)
        local path='/cache/large-'..uid..'.epub'
        many.chapters[index]={chapterUid=uid}
        many.cached_chapters[uid]=path
        existing_paths[path]=true
    end
    local target=many.cached_chapters['37']
    books['74']=many
    local check_network=host.isNetworkConnected
    host.isNetworkConnected=function() error('a locally available book checked the network') end
    expect(host:startBookReading(many) and opened_path==target,'bookshelf Read did not open the cached chapter')
    host.isNetworkConnected=check_network
    expect((path_probes[target] or 0)>0 and not path_probes[many.cached_chapters['1']]
        and not path_probes[many.cached_chapters['38']],
        'opening an exact cached chapter probed unrelated files')

    existing_paths[target]=nil
    opened_path=nil
    expect(host:openBookForReading(many,true,{check_only=true}) and not opened_path,
        'checking the nearest cache opened the reader')
    expect(host:openBookForReading(many) and opened_path==many.cached_chapters['36']
        and not path_probes[many.cached_chapters['38']],
        'a missing target did not try the preceding cached chapter first')
    books['74']=nil
end

do
    local old_catalog={
        book_id='75',progress=100,
        chapters={{chapterUid=1},{chapterUid=2},{chapterUid=3},{chapterUid=4},{chapterUid=5}},
        cached_chapters={['2']='/cache/2.epub',['5']='/cache/after-gap.epub'},
    }
    old_catalog.chapters[3]=nil
    existing_paths['/cache/after-gap.epub']=true
    expect(host:openBookForReading(old_catalog) and opened_path=='/cache/2.epub'
        and not path_probes['/cache/after-gap.epub'],'a gapped catalog changed the preferred cached chapter')
end

do
    local get_chapters, load_catalog = host.library_db.getChapters, content.load_catalog_cache
    local function unexpected_catalog() error('reading a catalog without a candidate download') end
    host.library_db.getChapters,content.load_catalog_cache=unexpected_catalog,unexpected_catalog
    opened_path=nil
    expect(not host:openBookForReading({book_id='78',chapter_uid=3},true,{prefer_exact=true}),
        'a book without a download mapping was considered cached')
    expect(not host:openBookForReading({book_id='78',cached_chapters={}},true,{prefer_exact=true}) and not opened_path,
        'an empty chapter mapping entered the reader')

    local original_owner=current_owner;current_owner=string.rep('d',20)
    local imported={book_id='CB_Cached',cached_chapters={['1']='/cache/imported-hint.epub'}}
    existing_paths['/cache/imported-hint.epub']=true
    local Hint=require('weread.lib.unindexed_resume')
    imported.cb_cloud_view_resume=assert(Hint.make({book_id=imported.book_id,chapter_uid='1',
        file_id=string.rep('c',64),raw_sha256=string.rep('e',64),basis='filtered_xhtml_utf16',
        upload_verified=false},imported.book_id,current_owner,0))
    local old_resume=package.loaded['weread.ui.unindexed_resume']
    local received
    package.loaded['weread.ui.unindexed_resume']={start=function(_,book,hint,paths,options)
        received={book=book,hint=hint,paths=paths,cloud=options.cloud_view};return true
    end}
    expect(host:openBookForReading(imported,true,{prefer_exact=true}) and received
        and received.book==imported and received.hint==imported.cb_cloud_view_resume and received.cloud
        and #received.paths==1 and received.paths[1]=='/cache/imported-hint.epub',
        'an imported-book hint should go directly to cache verification')
    package.loaded['weread.ui.unindexed_resume']=old_resume
    current_owner=original_owner
    host.library_db.getChapters,content.load_catalog_cache=get_chapters,load_catalog
end

do
    local scope={}
    local cached={book_id='76',chapters={{chapterUid=1},{chapterUid=2}},
        chapter_uid=1,cached_chapters={['1']='/cache/76-1.epub'}}
    local row={bookId='76',title='Legacy index'}
    existing_paths['/cache/76-1.epub']=true
    local prior_get,prior_download=host.settings.get_book,host.bookRecordHasDownload
    local reads,download_probes=0,0
    host.settings.get_book=function(_,id,allow_legacy)
        expect(id=='76','read from another book record')
        reads=reads+1
        if allow_legacy then return cached end
    end
    host.bookRecordHasDownload=function(_,record)
        expect(record==cached,'download check lost the verified record')
        download_probes=download_probes+1
        return true
    end
    host.shelf_view=scope
    local function current() return true end
    opened_path=nil
    expect(host:readFromBookList(row,scope,current) and opened_path=='/cache/76-1.epub'
        and reads==1 and download_probes==0,
        'direct shelf reading should reuse the legacy record and skip the download badge check')
    opened_path=nil
    expect(host:readFromBookList(row,scope,current,true) and opened_path=='/cache/76-1.epub'
        and reads==2 and download_probes==1,'opening a downloaded copy read the verified record twice')
    cached.chapter_uid=2;opened_path=nil
    expect(host:readFromBookList(row,scope,current,true) and reads==3 and not opened_path,
        'a missing chapter skipped the fallback confirmation')
    local before=path_probes['/cache/76-1.epub']
    local consent=last_dialog.ok_callback
    consent();consent()
    expect(reads==4 and opened_path=='/cache/76-1.epub' and path_probes['/cache/76-1.epub']==before+1,
        'fallback confirmation did not select the legacy cache with a single probe')
    cached.book_id='77';opened_path=nil
    expect(not host:readFromBookList(row,scope,current) and not opened_path and reads==5,
        'a conflicting cached record was opened from the shelf')
    host.settings.get_book,host.bookRecordHasDownload=prior_get,prior_download
    host.shelf_view=nil
end

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

-- Older cached-chapter maps can contain numeric keys. An exact local target
-- must not be reported missing merely because its catalog UID is a string.
partial.cached_chapters={[2]='/cache/2.epub',[4]='/cache/4.epub'}
partial.pending_upload_position={book_id='42',chapter_uid='4'}
partial.pending_upload_account='account-a'
opened_path=nil
expect(host:openBookForReading(partial,true,{prefer_exact=true}) and opened_path=='/cache/4.epub',
    'exact numeric-key cache was reported missing or opened another chapter')
partial.chapters={{chapterUid=2,chapterIdx=2}}
opened_path=nil
expect(host:openBookForReading(partial,true,{prefer_exact=true}) and opened_path=='/cache/4.epub',
    'the stale catalog took precedence over the exact cached resume chapter')
partial.chapters=original_catalog
partial.pending_upload_position.chapter_uid='9007199254740993'
partial.cached_chapters={[9007199254740992]='/cache/2.epub'}
opened_path=nil
local opened,missing_reason=host:openBookForReading(partial,true,{prefer_exact=true})
expect(not opened and missing_reason=='resume_not_cached' and not opened_path,
    'rounded numeric cache key was mistaken for an adjacent large chapter')
partial.cached_chapters={['2']='/cache/2.epub',['4']='/cache/4.epub'}
partial.pending_upload_position=nil

local hint_owner=string.rep('a',20)
local hinted=require('weread.lib.unindexed_resume').make({book_id='42',chapter_uid='4',file_id=string.rep('b',64),
    raw_sha256=string.rep('c',64),basis='filtered_xhtml_utf16',upload_verified=false},'42',hint_owner,0)
local pending_hint
package.loaded['weread.ui.unindexed_resume']={start=function(_host,_book,hint,paths)
    pending_hint={hint=hint,path=paths[1],paths=paths};return true
end,cancel=function() end}
current_owner=hint_owner;db_chapters=nil;partial.chapters=nil;partial.unindexed_resume=hinted
partial.full_path='/cache/full.epub';existing_paths[partial.full_path]=true
expect(host:openBookForReading(partial,true,{prefer_exact=true,check_only=true}) and not pending_hint,
    'checking the local-only chapter unexpectedly began an asynchronous open')
expect(host:openBookForReading(partial,true,{prefer_exact=true}) and pending_hint.path=='/cache/4.epub',
    'catalog-free hint did not select its verified chapter before another cached file')
expect(#pending_hint.paths==2 and pending_hint.paths[2]==partial.full_path,
    'both single-chapter and full-book caches were not offered for identity verification')
pending_hint=nil;current_owner=string.rep('d',20);opened_path=nil
host:openBookForReading(partial)
expect(not pending_hint and opened_path==partial.full_path,'foreign account used a local-only chapter hint')
current_owner=hint_owner;partial.chapters=original_catalog;opened_path=nil
host:openBookForReading(partial)
expect(not pending_hint and opened_path==partial.full_path,'restored catalog continued using the incomplete local hint')
partial.chapters=nil;existing_paths['/cache/4.epub']=nil;existing_paths[partial.full_path]=nil
local available,reason,uid=host:openBookForReading(partial,true,{prefer_exact=true})
expect(not available and reason=='resume_not_cached' and uid=='4','missing selected chapter was silently replaced')
opened_path=nil
expect(not host:openBookForReading(partial,true,{prefer_exact=true,confirmed_missing_uid='3'}) and not opened_path,
    'consent for a different chapter let an unindexed hint fall back')
expect(host:openBookForReading(partial,true,{prefer_exact=true,confirmed_missing_uid='4'}) and opened_path=='/cache/2.epub',
    'the confirmed unindexed hint did not allow a cached alternative')
local mappings=partial.cached_chapters
partial.cached_chapters={}
available,reason,uid=host:openBookForReading(partial,true,{prefer_exact=true})
expect(not available and reason=='resume_not_cached' and uid=='4',
    'an empty mapping discarded the ordinary catalog-free resume hint')
partial.cached_chapters=mappings
existing_paths['/cache/4.epub']=true;existing_paths[partial.full_path]=true;partial.unindexed_resume=nil;partial.chapters=original_catalog
partial.full_path=nil;current_owner='account-a';package.loaded['weread.ui.unindexed_resume']=nil

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
do
    local source=require('weread.lib.shelf_source')
    local old_web_access=source.web_access
    local authenticated,online=true,true
    source.web_access=function() return authenticated and {} or nil end
    host.isNetworkConnected=function() return online end
    local target={book_id='55',chapters={{chapterUid=1},{chapterUid=2},{chapterUid=3}},
        pending_upload_position={book_id='55',chapter_uid=3},cached_chapters={['1']='/cache/1.epub'}}
    books['55']=target;existing_paths['/cache/1.epub']=true
    opened_path,preparation=nil,nil
    expect(host:startBookReading(target,view) and preparation and preparation.book==target and not opened_path,
        'online Read opened a nearby chapter instead of preparing the missing resume chapter')
    online=false;opened_path,preparation=nil,nil
    expect(host:startBookReading(target,view) and not opened_path and not preparation and last_dialog,
        'offline Read did not warn before its cached fallback')
    local declined=last_dialog;declined.cancel_callback()
    expect(not opened_path and not host._missing_resume_confirmation,'declining fallback opened a chapter')
    expect(host:startBookReading(target,view) and last_dialog~=declined,'fallback warning was not reopened')
    last_dialog.ok_callback()
    expect(opened_path=='/cache/1.epub' and not preparation,'confirmed offline fallback did not open cache')
    online=true;authenticated=false;opened_path,preparation=nil,nil
    expect(host:startBookReading(target,view) and not opened_path and not preparation,
        'Read without Web access did not warn before fallback')
    last_dialog.ok_callback()
    expect(opened_path=='/cache/1.epub','confirmed fallback without Web access did not open cache')
    authenticated=true;target.cached_chapters['3']='/cache/3.epub';existing_paths['/cache/3.epub']=true
    opened_path,preparation=nil,nil
    expect(host:startBookReading(target,view) and opened_path=='/cache/3.epub' and not preparation,
        'online Read unnecessarily fetched an already cached exact chapter')
    target.cached_chapters['3']=nil;target.chapters=nil;db_chapters=nil
    opened_path,preparation=nil,nil
    expect(host:startBookReading(target,view) and preparation and not opened_path,
        'missing catalog caused an uncached pending UID to be ignored')
    target.pending_upload_account='another-owner';opened_path,preparation=nil,nil
    expect(host:startBookReading(target,view) and opened_path=='/cache/1.epub' and not preparation,
        'a foreign pending UID caused a download')
    target.pending_upload_account=nil;online=false;opened_path=nil
    expect(host:startBookReading(target,view) and not opened_path,'missing target did not show a warning')
    local pending_dialog=last_dialog;current_owner='account-b';pending_dialog.ok_callback();current_owner='account-a'
    expect(not opened_path,'warning callback crossed account boundary')
    host:cancelBookReading();opened_path=nil
    expect(host:startBookReading(target,view),'missing target warning did not open')
    pending_dialog=last_dialog;target.pending_upload_position.chapter_uid=2;pending_dialog.ok_callback()
    expect(not opened_path,'changed missing target opened a stale cached choice')
    target.pending_upload_position.chapter_uid=3
    expect(host:startBookReading(target,view),'warning was not shown before closing the page')
    pending_dialog=last_dialog;host:cancelBookReading();pending_dialog.ok_callback()
    expect(not opened_path and not host._missing_resume_confirmation,'closed warning retained an active callback')
    expect(host:startBookReading(target,view),'warning was not shown before cache changed')
    target.cached_chapters['3']='/cache/3.epub';last_dialog.ok_callback()
    expect(opened_path=='/cache/3.epub','newly cached exact chapter was not preferred after warning')
    target.cached_chapters['3']=nil;opened_path=nil
    expect(host:startBookReading(target,view) and not opened_path,'a missing chapter did not prompt again')
    target.cached_chapters['2']='/cache/2.epub';target.pending_upload_position.chapter_uid=2
    last_dialog.ok_callback()
    expect(opened_path=='/cache/2.epub','confirmation ignored a newer, already cached resume chapter')
    target.cached_chapters['2']=nil;target.pending_upload_position.chapter_uid=3

    local access=require('weread.lib.native_read_access')
    local capture=access.capture
    access.capture=function() return {} end
    local module='weread.ui.native_direct_reading'
    local previous=package.loaded[module]
    local shelf={};local function current() return true end
    local choice
    package.loaded[module]={start=function(_,book,owner,options)
        expect(book==uncached and owner==shelf and options.shelf_current==current,'reading lost the shelf owner')
        choice=options;return true
    end}
    host.shelf_view=shelf
    host.nativeChapterCachePresent=function(_,id) return id==uncached.book_id end
    host.bookRecordHasDownload=function() return false end
    online=true;authenticated=false
    expect(host:readFromBookList(uncached,shelf,current) and choice.cloud_chapter and not choice.cached,
        'partial E-Ink downloads hid the cloud continuation online')
    authenticated=true;choice=nil
    expect(host:readFromBookList(uncached,shelf,current) and choice.cached and not choice.cloud_chapter,
        'an available downloaded copy was bypassed when the Web account was present')
    prefer_eink=true;choice=nil
    expect(host:readFromBookList(uncached,shelf,current) and choice.cloud_chapter and not choice.cached,
        'the E-Ink preference did not choose native continuation with Web access')
    local continue_standard=choice.standard_read;choice,preparation=nil,nil
    local refreshed={book_id=uncached.book_id,title='Refreshed after choosing E-Ink'}
    books['99']=refreshed
    expect(continue_standard and continue_standard() and preparation and preparation.book==refreshed and not choice,
        'standard reading restarted native selection or reused the record from before confirmation')
    books['99']=uncached
    opened_path,choice=nil,nil
    expect(host:readFromBookList(partial,shelf,current) and opened_path==partial.full_path and not choice,
        'the E-Ink preference bypassed an existing ordinary EPUB')
    host.nativeChapterCachePresent=function() return false end
    choice,preparation=nil,nil;uncached.pending_upload_position={book_id='99',chapter_uid='4'}
    expect(host:readFromBookList(uncached,shelf,current) and preparation and not choice,
        'the E-Ink preference bypassed an unsynced ordinary reading position')
    uncached.pending_upload_account='another-owner';choice,preparation=nil,nil
    expect(host:readFromBookList(uncached,shelf,current) and choice and not preparation,
        'a foreign pending position blocked the E-Ink preference')
    uncached.pending_upload_position,uncached.pending_upload_account=nil,nil
    uncached.last_local_position={book_id='99',chapter_uid='4'};choice,preparation=nil,nil
    expect(host:readFromBookList(uncached,shelf,current) and preparation and not choice,
        'the E-Ink preference bypassed an ordinary local position')
    uncached.last_local_position=nil;access.capture=function() return {renewal_pending=true} end
    choice,preparation=nil,nil
    expect(host:readFromBookList(uncached,shelf,current) and preparation and not choice,
        'an unavailable native authorization blocked regular reading')
    prefer_eink=false
    host.shelf_view=nil;host.nativeChapterCachePresent=nil;host.bookRecordHasDownload=nil
    package.loaded[module]=previous;access.capture=capture
    source.web_access=old_web_access;host.isNetworkConnected=nil
end
local detail_data
package.preload['weread.ui.book_detail_view']=function() return {show=function(data) detail_data=data;return {} end} end
local detail_book={book_id='42',title='Synthetic book',chapters={{chapterUid=1},{chapterUid=2},{chapterUid=3}},
    cached_chapters={['1']='/cache/1.epub',['2']='/cache/2.epub',['unknown']='/cache/unknown.epub'}}
existing_paths['/cache/1.epub']=true;existing_paths['/cache/2.epub']=true;existing_paths['/cache/unknown.epub']=true
books['42']=detail_book
detail_book.full_path='/cache/full.epub';existing_paths[detail_book.full_path]=true
detail_book.cached_full_book=detail_book.full_path
host.safeCallback=function(_self,_title,callback) return callback end
path_probes={}
Library.showBookMenu(host,detail_book)
expect(detail_data.status_line=='Full book cached','full download with separate chapters displayed a partial count')
expect(path_probes[detail_book.full_path]==1 and not path_probes['/cache/1.epub'],
    'detail probed individual cached chapters despite a recorded full download')
do
    local module='weread.ui.native_home_resume'
    local previous=package.loaded[module]
    local old_scope,old_matches=host.settings.get_auth_scope,host.settings.auth_scope_matches
    local scope={vid='42',epoch=1}
    host.settings.get_auth_scope=function() return scope end
    host.settings.auth_scope_matches=function(_,value) return value==scope end
    local native_opened
    package.loaded[module]={can_resume=function(_,record) return record.native_home_resume~=nil end,
        open_detail=function(_,record,id,owner_view)
            native_opened=record==detail_book and id=='42' and owner_view==host._book_detail_view
        end}
    detail_book.native_home_resume={}
    Library.showBookMenu(host,detail_book)
    local standard
    for _,action in ipairs(detail_data.actions) do if action.text=='Read standard download' then standard=action.callback end end
    expect(standard and detail_data.bottom_actions[3].text=='▤ Continue reading',
        'dual-copy detail cannot reach the ordinary EPUB without replacing native resume')
    detail_data.bottom_actions[3].callback()
    expect(native_opened,'primary footer stopped using native resume')
    opened_path=nil;standard()
    expect(opened_path==detail_book.full_path,'manual ordinary download opened a different source')
    host._book_detail_view={};opened_path=nil;standard()
    expect(not opened_path,'old ordinary download action opened after replacement')
    detail_book.native_home_resume=nil
    host.settings.get_auth_scope,host.settings.auth_scope_matches=old_scope,old_matches
    package.loaded[module]=previous
end
detail_book.chapters=nil;Library.showBookMenu(host,detail_book)
expect(detail_data.status_line=='Full book cached','full download without a catalog displayed a partial count')
detail_book.full_path=nil;detail_book.cached_full_book=nil;detail_book.chapters={{chapterUid=1},{chapterUid=2},{chapterUid=3}}
detail_book.cached_file='/cache/1.epub';detail_book.cached_chapters['3']='/cache/1.epub'
detail_book.cached_chapters.missing='/cache/missing.epub';detail_book.cached_chapters.missing_alias='/cache/missing.epub'
path_probes={}
Library.showBookMenu(host,detail_book)
expect(detail_data.status_line=='Cached 2/3 chapters','partial download lost the count status')
expect(path_probes['/cache/1.epub']==1 and path_probes['/cache/missing.epub']==1,
    'cached and missing paths were probed repeatedly within one detail render')
detail_book.cached_file=nil;detail_book.cached_chapters['3']=nil
detail_book.cached_chapters.missing=nil;detail_book.cached_chapters.missing_alias=nil
Library.showBookMenu(host,detail_book)
local cached_action
for _,action in ipairs(detail_data.actions) do if action.text=='Read cached copy' then cached_action=action end end
expect(cached_action~=nil,'partial cache has no explicit cached reading action')
opened_path=nil;cached_action.callback()
expect(opened_path=='/cache/1.epub','cached reading action did not open an available chapter')
host._book_detail_view={};opened_path=nil;cached_action.callback()
expect(not opened_path,'stale cached reading action opened a book')
Library.showBookMenu(host,detail_book);cached_action=nil
for _,action in ipairs(detail_data.actions) do if action.text=='Read cached copy' then cached_action=action end end
current_owner='account-b';opened_path=nil;cached_action.callback()
expect(not opened_path,'cached reading action crossed account boundary');current_owner='account-a'
detail_book.cached_file=nil;detail_book.cached_chapters={unknown='/cache/unknown.epub'}
Library.showBookMenu(host,detail_book);cached_action=nil
for _,action in ipairs(detail_data.actions) do if action.text=='Read cached copy' then cached_action=action end end
expect(cached_action~=nil,'cached chapter missing from an old catalog has no manual reading action')
opened_path=nil;cached_action.callback()
expect(opened_path=='/cache/unknown.epub','manual reading could not open a chapter outside the old catalog')
do
    local source=require('weread.lib.shelf_source')
    local access=require('weread.lib.native_read_access')
    local native=require('weread.ui.native_direct_reading')
    local old_web_access,old_capture,old_start=source.web_access,access.capture,native.start
    local old_catalog,old_download=host.showChapterList,host.confirmDownloadAllChapters
    local web,route=false,nil
    source.web_access=function() return web and {} or nil end
    access.capture=function() return {} end
    native.start=function(_self,book,owner,options)
        expect(book==detail_book and owner==host._book_detail_view,'native action changed the selected book or view')
        route=options
    end
    host.showChapterList=function() route='web catalog' end
    host.confirmDownloadAllChapters=function() route='web download' end
    Library.showBookMenu(host,detail_book)
    local download,catalog=unpack(detail_data.bottom_actions)
    expect(download.text=='⇩ E-Ink download','native-only download advertised a merged EPUB')
    for _,action in ipairs(detail_data.actions) do
        expect(action.text~='Download E-Ink chapters','native download appeared twice')
    end
    catalog.callback();expect(type(route)=='table' and not route.cached and not route.batch,'primary catalog did not use native entries')
    download.callback();expect(type(route)=='table' and route.batch,'primary download did not offer a native chapter batch')
    current_owner='account-b';route=nil
    catalog.callback();download.callback();expect(not route,'stale primary action crossed accounts')
    current_owner='account-a';web=true;Library.showBookMenu(host,detail_book)
    download,catalog=unpack(detail_data.bottom_actions)
    expect(download.text=='⇩ Download full book','ordinary full-book download label changed')
    catalog.callback();expect(route=='web catalog','dual login changed the ordinary catalog')
    download.callback();expect(route=='web download','dual login changed merged download')
    Library.showBookMenu(host,detail_book,{read_saved_native=true})
    detail_data.bottom_actions[2].callback()
    expect(type(route)=='table' and route.cached,'details opened from downloaded native books did not show saved chapters')
    source.web_access,access.capture,native.start=old_web_access,old_capture,old_start
    host.showChapterList,host.confirmDownloadAllChapters=old_catalog,old_download
end
local recovery_calls=0
local previous_recovery=package.loaded['weread.ui.download_recovery']
package.loaded['weread.ui.download_recovery']={start=function() recovery_calls=recovery_calls+1 end}
local confirmed_book={book_id='42'}
Library.confirmAndDownloadChapters(host,confirmed_book,{{chapterUid=1}},'chapter',{single_chapter=true})
local active_confirmation=last_dialog;active_confirmation.ok_callback()
expect(recovery_calls==1,'current confirmation did not start the selected download')
Library.confirmAndDownloadChapters(host,confirmed_book,{{chapterUid=1}},'chapter',{single_chapter=true})
local stale_confirmation=last_dialog;current_owner='account-b';stale_confirmation.ok_callback();current_owner='account-a'
expect(recovery_calls==1,'stale confirmation crossed account boundaries')
Library.confirmAndDownloadChapters(host,confirmed_book,{{chapterUid=1}},'chapter',{single_chapter=true})
stale_confirmation=last_dialog;confirmed_book.book_id='43';stale_confirmation.ok_callback()
expect(recovery_calls==1,'stale confirmation downloaded a different book')
package.loaded['weread.ui.download_recovery']=previous_recovery
local old_context=package.loaded['weread.lib.source_context']
package.loaded['weread.lib.source_context']={location=function(document) return {page=document.page} end,
    same_location=function(a,b) return a and b and a.page==b.page end}
local promoted
host.downloader={promotePrefetch=function(_,_,_,guard) promoted=guard;return true end}
host.ui={document={file='/current.epub',page=1},view={view_mode='page'}}
host._reader_session_gen=1;host.progress_sync={navigation_generation=1};host._chapter_list_view={}
local epoch=1
host.settings.get_auth_scope=function() return {vid='42',epoch=epoch} end
host.settings.auth_scope_matches=function(_,scope) return scope.epoch==epoch end
local selected_book={book_id='42'};local selected_chapter={chapterUid=2}
do
    local original_promote=host.downloader.promotePrefetch
    host.downloader.promotePrefetch=function() return false end
    local finished,refresh_catalog
    host:openChapter(selected_book,selected_chapter,function(_,refresh) finished,refresh_catalog=true,refresh end)
    local download=assert(single_download_options)
    expect(download.read_current and download.read_current() and download.recovery_current(),
        'an uncached chapter missed its reading and confirmation guards')
    host.ui.document.page=2
    expect(not download.read_current() and not download.recovery_current(),
        'a page change retained a pending chapter download action')
    download.on_complete(true,'/cache/2.epub')
    expect(not finished,'an obsolete download refreshed the chapter list')
    host.ui.document.page=1
    host:openChapter(selected_book,selected_chapter,function(_,refresh) refresh_catalog=refresh end)
    download=assert(single_download_options)
    download.on_complete(true,'/cache/2.epub')
    local old_view=host._chapter_list_view
    refresh_catalog(function()
        old_view._catalog_closed=true
        host._chapter_list_view={}
        return host._chapter_list_view
    end)
    expect(download.read_current(),'its own catalogue refresh blocked the current Read now offer')
    host._chapter_list_view._catalog_closed=true
    expect(not download.read_current(),'closing the refreshed catalogue retained the offer')
    host._chapter_list_view={}
    host.downloader.promotePrefetch=original_promote
end
host:openChapter(selected_book,selected_chapter)
local first_intent=assert(promoted);expect(first_intent(),'current promoted chapter lost its guard')
host.ui.document.page=2;expect(not first_intent(),'page change retained old promoted chapter');host.ui.document.page=1
host.progress_sync.navigation_generation=2;expect(not first_intent(),'new navigation retained old promoted chapter');host.progress_sync.navigation_generation=1
epoch=2;expect(not first_intent(),'account change retained old promoted chapter');epoch=1
host._chapter_list_view._catalog_closed=true;expect(not first_intent(),'closed chapter list retained old promoted chapter');host._chapter_list_view._catalog_closed=false
selected_chapter.chapterUid=3;expect(not first_intent(),'changed selected chapter retained old promotion');selected_chapter.chapterUid=2
host:openChapter(selected_book,selected_chapter)
expect(not first_intent() and promoted(),'later chapter selection did not supersede old promotion')

local old_claims=package.loaded['weread.lib.chapter_cache_claim']
local old_navigation=package.loaded['weread.ui.combined_chapter_navigation']
local proof={kind='combined',items={chapter_2=true},file_id='sealed'}
local single_valid=false
package.loaded['weread.lib.chapter_cache_claim']={
    combined=function(_,path) if path=='/cache/full.epub' then return proof end end,
    inspect=function() return {kind='unknown'} end,
    usable=function() return single_valid end,
    chapter_readable=function() return true end,
    shared=function() return false end,
    complete=function() return true end,
}
local navigated
package.loaded['weread.ui.combined_chapter_navigation']={open=function(_,_,_,path,guard,actual,is_partial)
    navigated={path=path,current=guard(),proof=actual,partial=is_partial};return true
end}
selected_book.full_path='/cache/full.epub'
selected_book.cached_chapters={['2']='/cache/missing.epub'}
selected_book.chapters={selected_chapter}
existing_paths['/cache/full.epub']=true
host:openChapter(selected_book,selected_chapter)
expect(navigated and navigated.path==selected_book.full_path and navigated.current and navigated.proof==proof,
    'missing single-chapter cache hid a verified combined book')
navigated=nil;existing_paths['/cache/missing.epub']=true
host:openChapter(selected_book,selected_chapter)
expect(navigated and navigated.path==selected_book.full_path,
    'unusable single-chapter cache hid a verified combined book')
navigated=nil;opened_path=nil;single_valid=true
host:openChapter(selected_book,selected_chapter)
expect(not navigated and opened_path=='/cache/missing.epub',
    'verified single chapter lost priority to a different combined book')
navigated=nil;single_valid=false;proof.items={chapter_4=true};single_download_options=nil
host:openChapter(selected_book,selected_chapter)
expect(not navigated and single_download_options and single_download_options.single_chapter,
    'combined book without the target bypassed the ambiguous-cache warning')
do
    selected_book.chapter_uid=2;opened_path=nil
    selected_book.cached_chapters={}
    local combined_available,combined_reason,combined_uid=host:openBookForReading(selected_book,true,{prefer_exact=true,
        confirmed_missing_uid='3',check_only=true})
    expect(not combined_available and combined_reason=='resume_not_cached' and combined_uid=='2' and not opened_path,
        'unshared combined book lost its missing chapter or accepted consent for another chapter')
    expect(host:openBookForReading(selected_book,true,{prefer_exact=true,confirmed_missing_uid='2'})
        and opened_path==selected_book.full_path,'consent did not allow the verified incomplete combined book')
    opened_path=nil
    selected_book.cached_chapters={['2']=selected_book.full_path,[2]='/cache/missing.epub'}
    single_valid=true
    expect(host:openBookForReading(selected_book,true,{prefer_exact=true,check_only=true}) and not opened_path,
        'checking an exact cached copy opened a document')
    expect(host:openBookForReading(selected_book,true,{prefer_exact=true,confirmed_missing_uid='2'})
        and opened_path=='/cache/missing.epub','a newly available exact copy lost priority to the incomplete combined book')
    selected_book.cached_chapters={['2']='/cache/missing.epub'}
    single_valid=false
end
do
    local claim=require('weread.lib.chapter_cache_claim')
    local old_usable=claim.usable
    local good='/cache/legacy-2.epub'
    existing_paths['/cache/missing.epub']=true
    existing_paths[good]=true
    selected_book.cached_chapters={['2']='/cache/missing.epub',[2]=good}
    claim.usable=function(_,path,_,_,strict)
        expect(strict,'two mappings were selected without checking the EPUB identity')
        return path==good
    end
    for _,cached_only in ipairs({false,true}) do
        opened_path=nil;navigated=nil
        expect(host:openChapter(selected_book,selected_chapter,nil,{cached_only=cached_only})
            and opened_path==good and not navigated,'an invalid primary mapping hid a second verified chapter')
    end
    claim.usable=old_usable
    existing_paths[good]=nil
    selected_book.cached_chapters={['2']='/cache/missing.epub'}
end
local old_info, unavailable = host.showInfo
host.showInfo=function(_,text) unavailable=text end
single_download_options=nil;opened_path=nil;promoted=nil
for _,exists in ipairs({true,false}) do
    existing_paths['/cache/missing.epub']=exists
    expect(not host:openChapter(selected_book,selected_chapter,nil,{cached_only=true})
        and not navigated and not opened_path and not single_download_options and not promoted
        and unavailable=='The downloaded chapter is unavailable or could not be verified.',
        'unavailable saved chapter proceeded to a download or opened an unverified file')
end
host.showInfo=old_info
package.loaded['weread.lib.chapter_cache_claim']=old_claims
package.loaded['weread.ui.combined_chapter_navigation']=old_navigation
package.loaded['weread.lib.source_context']=old_context
print(("library_cache_flow_spec: %d checks"):format(checks))

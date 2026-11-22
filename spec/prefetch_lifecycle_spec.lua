-- Focused tests for next-chapter selection and one-second prefetch notices.

package.path = "./?.lua;" .. package.path

local existing = {}
local logs = {}
local scheduled = {}
package.preload["weread.lib.content"] = function()
    return {
        catalog_cache_path = function() return "/cache/catalog.json" end,
        save_catalog_cache = function() return true end,
    }
end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            return {
                info = function(...) logs[#logs + 1] = { "info", ... } end,
                warn = function(...) logs[#logs + 1] = { "warn", ... } end,
            }
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function(book_id) return book_id == "mp-book" end }
end
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_self,_delay,callback) scheduled[#scheduled+1]=callback end }
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
        display_error = function(value) return tostring(value) end,
        log_error = function(value) return tostring(value) end,
        file_exists = function(path) return existing[path] == true end,
    }
end

local Lifecycle = require("weread.lib.reader_lifecycle")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local chapters = {
    { chapterUid = 1, title = "One" },
    { chapterUid = 2, title = "Two" },
    { chapterUid = 3, title = "Three" },
}
local book = {
    book_id = "book",
    chapters = chapters,
    cached_chapters = { ["1"] = "/cache/one.epub" },
}
existing["/cache/one.epub"] = true

local cache = {
    auto_prefetch_next_chapter = true,
    show_prefetch_notifications = true,
    download_underlines_and_thoughts = true,
}
local starts = {}
local notices = {}
local downloader = {
    cancelPrefetch = function() end,
    isPrefetching = function() return false end,
    isPromotedPrefetch = function() return false end,
    start = function(_self, target_book, target_chapters, suffix, options)
        starts[#starts + 1] = {
            book = target_book,
            chapters = target_chapters,
            suffix = suffix,
            options = options,
        }
        return true
    end,
}
local host = {
    settings = {
        get = function(_self, key)
            if key == "cache" then return cache end
            if key == "books" then return { book = book } end
        end,
    },
    downloader = downloader,
    ui = { document = { file = "/cache/one.epub" } },
    ensureChaptersLoaded = function() return chapters end,
    showTransientInfo = function(_self, text, timeout)
        notices[#notices + 1] = { text, timeout }
    end,
    detectWeReadBook = function() return nil end,
    requireLogin = function() return true end,
    progress_sync = { sync_now = function() end },
}
for key, value in pairs(Lifecycle) do host[key] = value end
host.detectWeReadBook = function() return nil end

expect(host:maybePrefetchNextChapter("book"), "prefetch request accepted")
expect(#starts == 1 and starts[1].chapters[1] == chapters[2],
    "only the immediate next chapter is selected")
expect(starts[1].options.include_annotations == false,
    "prefetch creates clean text regardless of the legacy annotation preference")
expect(starts[1].options.start_delay == 0.7,
    "visible start notice gets time to close before network work")

starts[1].options.on_start()
starts[1].options.on_complete(true, "/cache/two.epub")
expect(#notices == 2 and notices[1][2] == 0.5 and notices[2][2] == 1,
    "start notice lasts half a second and completion lasts one second")
expect(#logs == 2 and logs[1][1] == "info" and logs[2][1] == "info",
    "prefetch start and success are logged")

starts = {}
notices = {}
book.cached_chapters["2"] = "/cache/two.epub"
existing["/cache/two.epub"] = true
expect(host:maybePrefetchNextChapter("book"), "cached next chapter is satisfied")
expect(#starts == 0, "cached next chapter does not scan forward to chapter three")

book.cached_chapters["2"] = nil
existing["/cache/two.epub"] = nil
host:maybePrefetchNextChapter("book")
starts[1].options.on_complete(false, "offline")
expect(#notices == 1
    and notices[1][1]:find("Network is not connected", 1, true) ~= nil,
    "offline prefetch reports a failure")
expect(logs[#logs][1] == "warn", "prefetch failure is logged")

cache.show_prefetch_notifications = false
starts = {}
host:maybePrefetchNextChapter("book")
expect(starts[1].options.start_delay == 0.1,
    "silent prefetch does not pay the notification grace delay")
starts[1].options.on_start()
starts[1].options.on_complete(false, "network error")
expect(#notices == 1, "notification setting silences all prefetch notices")

local retry_valid=true
local retried,information=0,nil
host.downloadChapterAndRead=function() retried=retried+1 end
host.showInfo=function(_,text) information=text end
downloader.isPromotedPrefetch=function() return true,function() return retry_valid end end
starts={};scheduled={};host:maybePrefetchNextChapter('book')
starts[1].options.on_complete(false,'network error')
expect(#scheduled==1,'promoted prefetch did not schedule its fallback confirmation')
retry_valid=false;table.remove(scheduled,1)()
expect(retried==0,'stale promoted prefetch opened a delayed download confirmation')
retry_valid=true;starts={};scheduled={};host:maybePrefetchNextChapter('book')
starts[1].options.on_complete(false,'network error');table.remove(scheduled,1)()
expect(retried==1,'current promoted prefetch lost its fallback confirmation')
starts={};scheduled={};host:maybePrefetchNextChapter('book')
starts[1].options.on_complete(false,'rate_limited')
expect(#scheduled==0 and information and information:find('limiting requests',1,true),
    'promoted rate-limited prefetch reopened download or hid the failure')
for _,reason in ipairs({'native_auth_expired','native_resource_failed'}) do
    starts={};scheduled={};information=nil;host:maybePrefetchNextChapter('book')
    starts[1].options.on_complete(false,reason)
    expect(#scheduled==0 and information and retried==1,
        'promoted native prefetch retried or hid '..reason)
end
starts={};scheduled={};information=nil;host:maybePrefetchNextChapter('book')
starts[1].options.on_complete(false,'book_identity_conflict')
expect(#scheduled==0 and information and information:find('does not match',1,true),
    'promoted prefetch retried or hid a conflicting saved book identity')
local original_get=host.settings.get
host.settings.get=function(self,key)
    if key=='books' then return {book={book_id='another',chapters=chapters}} end
    return original_get(self,key)
end
starts={};expect(not host:maybePrefetchNextChapter('book') and #starts==0,
    'prefetch started with a saved book that has a conflicting identity')
local cancelled
downloader.getActivePrefetch=function() return {book=book,chapters={chapters[2]}} end
downloader.cancelPrefetch=function(_,reason) cancelled=reason end
information=nil;expect(not host:maybePrefetchNextChapter('book') and cancelled=='book_identity_handled'
    and information and information:find('does not match',1,true),
    'an already selected prefetch was silently cancelled after an identity conflict')
downloader.getActivePrefetch=nil;downloader.cancelPrefetch=function() end
host.settings.get=original_get
downloader.isPromotedPrefetch=function() return false end
book.bookVersion=7;starts={};scheduled={}
local valid_chapter={chapterUid='2',title='Two',wordCount=0,level=1}
expect(host:maybePrefetchNextChapter('book',{chapter_uid='2',chapter=valid_chapter,previous_version=7,version=0})
    and #starts==1 and starts[1].book~=book and starts[1].book.bookVersion==0 and book.bookVersion==7,
    'recovered prefetch did not use an isolated unknown-version book')
starts={}
expect(not host:maybePrefetchNextChapter('book',{chapter_uid='3',chapter=valid_chapter,previous_version=7,version=0}) and #starts==0,
    'recovered prefetch accepted another target chapter')
expect(not host:maybePrefetchNextChapter('book',{chapter_uid='2',chapter=valid_chapter,previous_version=8,version=0}) and #starts==0,
    'recovered prefetch accepted an old book version')
chapters[2].title='Changed'
expect(not host:maybePrefetchNextChapter('book',{chapter_uid='2',chapter=valid_chapter,previous_version=7,version=0}) and #starts==0,
    'recovered prefetch accepted changed chapter metadata')
chapters[2].title='Two'
local original_finish=package.loaded['weread.ui.finish_offline']
package.loaded['weread.ui.finish_offline']={pump=function() end}
local resumed,account_epoch=0,1
host.progress_sync.on_resume=function() end
host.read_report={on_resume=function() end}
host.settings.auth_scope_matches=function(_,scope) return scope.epoch==account_epoch end
host.maybePrefetchNextChapter=function(_,id) assert(id=='book');resumed=resumed+1 end
host._current_weread_book_id='book';host._reader_session_gen=1
for _,change in ipairs({'none','account','session','book'}) do
    scheduled={};account_epoch=1;host._reader_session_gen=1;host._current_weread_book_id='book'
    host._resume_chapter_prefetch={book_id='book',session=1,scope={vid='900000',epoch=1}}
    Lifecycle.onResume(host)
    expect(#scheduled==1 and not host._resume_chapter_prefetch,'wake did not consume and defer the prefetch intent')
    if change=='account' then account_epoch=2
    elseif change=='session' then host._reader_session_gen=2
    elseif change=='book' then host._current_weread_book_id='other' end
    local previous=resumed;table.remove(scheduled,1)()
    expect(resumed==previous+(change=='none' and 1 or 0),'wake accepted wrong prefetch context: '..change)
end
package.loaded['weread.ui.finish_offline']=original_finish

local legacy_single = {
    cached_file = "/cache/one.epub",
    cached_chapters = { ["1"] = "/cache/one.epub" },
}
expect(host:getFullBookCachePath(legacy_single) == nil,
    "legacy single chapter is not mistaken for a full book")
legacy_single.cached_chapters["2"] = "/cache/one.epub"
expect(host:getFullBookCachePath(legacy_single) == nil,
    "an unverified shared cache is not assumed to be a full book")
legacy_single.chapters={{chapterUid=1}}
legacy_single.cached_chapters={['1']='/cache/one.epub',[1]='/cache/one.epub'}
local legacy_index,legacy_chapter,legacy_full=host:getChapterInfoFromFile(legacy_single,'/cache/one.epub')
expect(legacy_index==1 and legacy_chapter==legacy_single.chapters[1] and not legacy_full,
    'numeric and string aliases of one chapter were mistaken for multiple chapters')
legacy_single.chapters={{chapterId=1}}
legacy_index,legacy_chapter,legacy_full=host:getChapterInfoFromFile(legacy_single,'/cache/one.epub')
expect(legacy_index==1 and legacy_chapter==legacy_single.chapters[1] and not legacy_full,
    'chapterId-only legacy catalog lost its chapter mapping')

notices = {}
expect(not host:onWeReadSyncProgress(),
    "standalone sync gesture rejects a local document")
expect(notices[1] and notices[1][2] == 1,
    "standalone sync gesture explains missing WeRead context")

print(string.format(
    "prefetch_lifecycle_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)

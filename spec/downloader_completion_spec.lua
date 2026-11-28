-- Focused tests for automatic opening after a progress-target chapter download.
-- Run from the repo root with:
--   lua spec/downloader_completion_spec.lua

package.path = "./?.lua;" .. package.path

local shown = {}
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget end,
        preventStandby = function() end,
        allowStandby = function() end,
    }
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
local full_book_save_count = 0
local saved_cover_data
local packaged_text = {}
package.preload["weread.lib.content"] = function()
    return {
        register_annotation_document = function(book, path, chapters)
            book.annotation_documents = book.annotation_documents or {}
            book.annotation_documents[path] = { chapters = chapters }
        end,
        save_chapter_epub = function(_settings, _book, chapter, text)
            packaged_text[chapter.chapterUid] = text
            return "/cache/book/chapter-" .. tostring(chapter.chapterUid) .. ".epub"
        end,
        finalize_single_chapter_content = function(_, _, _, _, text) return text, {} end,
        stage_download_chapter_text = function(workspace, index, text)
            if workspace.fail then return nil, "injected storage failure" end
            workspace.text[index] = text
            return true
        end,
        load_download_chapter_text = function(workspace, index) return workspace.text[index] end,
        cleanup_download_workspace = function(workspace) workspace.cleaned = true end,
        save_book_epub = function(_settings, _book, _chapters, _bodies, _suffix, _assets, _css, cover_data)
            full_book_save_count = full_book_save_count + 1
            saved_cover_data = cover_data
            return "/cache/book/replacement-full.epub"
        end,
    }
end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.thoughts"] = function()
    return { is_download_enabled = function() return false end }
end
local Protocol = require("weread.lib.protocol")
local BookStore = require("weread.lib.book_store")

local Downloader = require("weread.lib.downloader")

local failures, checks = 0, 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

local stored_books
local live_books = {
    book = {
        book_id = "book",
        progress = 88,
        cached_chapters = { existing = "/cache/book/existing.epub" },
        annotation_documents = { ["/cache/book/concurrent.epub"] = { chapters = { { chapterUid = 99 } } } },
    },
}
local opened
local info_messages = {}
local completion_count = 0
local completion_ok
local completion_path
local store_failure
local settings = {
    get = function(_self, key)
        assert(key ~= "books", "download completion read the entire library")
        if key == "cache" then return {} end
    end,
    record_download = function(_self, id, _, change)
        if store_failure then return false, "injected metadata failure" end
        local record = assert(live_books[id])
        BookStore.apply_download(record, change)
        stored_books = live_books
        return true, record
    end,
    flush = function() end,
}
local downloader = Downloader:new{
    settings = settings,
    client = {},
    refresh_shelf = function() end,
    open_file = function(path) opened = path end,
    safe_callback = function(_, fn) return fn end,
    show_info = function(text) info_messages[#info_messages + 1] = text end,
    show_transient = function() end,
}
local chapter = { chapterUid = 22, title = "Target" }
local download = {
    book = { book_id = "book", title = "Book", annotation_documents = {
        ["/cache/book/stale.epub"] = { chapters = { { chapterUid = 1 } } },
    } },
    chapters = { chapter },
    selected = { chapter },
    bodies = { ["22"] = "<p>body</p>" },
    assets = {},
    state = { css = "" },
    suffix = "chapter",
    index = 2,
    total = 1,
    failed = {},
    annotation_failed_batches = 0,
    single_chapter = true,
    open_on_complete = true,
    started_at = 999,
    on_complete = function(ok, path)
        completion_count = completion_count + 1
        completion_ok = ok
        completion_path = path
    end,
}

downloader:_step(download)

eq(completion_count, 1, "completion callback count")
eq(completion_ok, true, "completion success")
eq(completion_path, "/cache/book/chapter-22.epub", "completion path")
eq(opened, "/cache/book/chapter-22.epub", "automatically opened path")
eq(#shown, 0, "no redundant read-now dialog")
eq(stored_books.book.cached_chapters["22"],
    "/cache/book/chapter-22.epub", "target chapter persisted")
eq(stored_books.book.progress, 88,
    "download cache merge preserved newer reading progress")
eq(stored_books.book.cached_chapters.existing, "/cache/book/existing.epub",
    "download cache merge preserved unrelated chapter mappings")

eq(stored_books.book.annotation_documents["/cache/book/concurrent.epub"].chapters[1].chapterUid,
    99, "background packaging preserved concurrent document mappings")
eq(stored_books.book.annotation_documents["/cache/book/stale.epub"], nil,
    "background snapshot did not replace current document mappings")
eq(stored_books.book.annotation_documents["/cache/book/chapter-22.epub"].chapters[1].chapterUid,
    22, "parent registered only the completed document")

do
    local current=false
    local function completed()
        local job={}
        for key,value in pairs(download) do job[key]=value end
        job.completion_notified=nil
        job.open_on_complete=false
        job.offer_read=true
        job.read_current=function() return current end
        downloader._active_job=job
        downloader:_step(job)
    end
    opened=nil
    completed()
    eq(#shown,0,"stale chapter download did not display a reading prompt")
    eq(stored_books.book.cached_chapters["22"],"/cache/book/chapter-22.epub","stale navigation kept the completed cache")
    current=true
    completed()
    local prompt=table.remove(shown)
    eq(type(prompt),"table","current chapter download displayed a reading prompt")
    if prompt then
        current=false
        prompt.ok_callback()
        eq(opened,nil,"a late Read now click did not change chapter")
    end
    current=true
    completed()
    local valid_prompt=assert(table.remove(shown))
    valid_prompt.ok_callback()
    eq(opened,"/cache/book/chapter-22.epub","a current Read now click opened the downloaded chapter")
    local queued_reason
    eq(downloader:start(download.book,{chapter},"chapter",{read_current=function() return false end,
        on_complete=function(ok,reason) if not ok then queued_reason=reason end end}),false,
        "a queued chapter with a stale reading intent did not start")
    eq(queued_reason,"navigation_changed","the queued action was released")
end

do
    local job = {}
    for key, value in pairs(download) do job[key] = value end
    job.completion_notified = nil
    job.book = { book_id = "book", title = "Book" }
    opened = nil
    store_failure = true
    downloader._active_job = job
    downloader:_step(job)
    eq(completion_ok, false, "failed metadata commit reports failure")
    eq(completion_path, "download_cache_unavailable", "failed metadata commit has a stable reason")
    eq(opened, nil, "unregistered EPUB was not opened")
    eq(job.book.cached_chapters, nil, "failed commit did not publish cache paths in memory")
    eq(downloader._active_job, nil, "failed metadata commit released the active job")
    table.remove(info_messages)
    store_failure = nil
end

local chapter_33 = { chapterUid = 33, title = "Other" }
local missing = { chapterUid = 44, title = "Unavailable" }
local chapter_workspace = {text = {}}
live_books.book.cached_file = "/cache/book/full.epub"
live_books.book.cached_full_book = "/cache/book/full.epub"
local separate = {
    book = {
        book_id = "book",
        title = "Book",
        cached_file = "/cache/book/full.epub",
        cached_full_book = "/cache/book/full.epub",
    },
    chapters = { chapter, missing, chapter_33 },
    selected = {},
    bodies = {},
    workspace = chapter_workspace,
    assets = {},
    assets_by_uid = { ["22"] = {}, ["33"] = {} },
    state = { css = "" },
    suffix = "chapters",
    index = 1,
    total = 3,
    failed = {},
    annotation_failed_batches = 0,
    separate_chapters = true,
    silent_completion = true,
    started_at = 999,
}
local failures_before = #info_messages
local schedule = downloader._scheduleGuarded
downloader._scheduleGuarded = function() end
separate.current = { chapter = chapter, xhtml = "<p>22</p>" }
downloader:_finishChapter(separate)
downloader:_failChapter(separate, "injected chapter source failure")
separate.current = { chapter = chapter_33, xhtml = "<p>33</p>" }
downloader:_finishChapter(separate)
downloader._scheduleGuarded = schedule
eq(next(separate.bodies), nil, "batch chapter bodies were released before packaging")
eq(chapter_workspace.text[2], "<p>33</p>", "a failed source did not shift the staged chapter order")
downloader:_step(separate)
eq(packaged_text[22], "<p>22</p>", "first EPUB received its staged chapter")
eq(packaged_text[33], "<p>33</p>", "second EPUB received its staged chapter")
eq(chapter_workspace.cleaned, true, "successful packaging removed staged text")
eq(stored_books.book.cached_chapters["22"],
    "/cache/book/chapter-22.epub", "first selected chapter persisted separately")
eq(stored_books.book.cached_chapters["33"],
    "/cache/book/chapter-33.epub", "second selected chapter persisted separately")
eq(stored_books.book.cached_full_book, "/cache/book/full.epub",
    "partial download preserved the full-book cache")

local failed_workspace = {text = {}, fail = true}
local storage_job = {book = separate.book, chapters = {chapter_33}, selected = {}, state = {},
    index = 1, total = 1, bodies = {}, workspace = failed_workspace, separate_chapters = true,
    current = {chapter = chapter_33, xhtml = "<p>unsaved text</p>"},
    on_complete = function(ok, reason) completion_ok, completion_path = ok, reason end}
downloader._active_job = storage_job
downloader:_finishChapter(storage_job)
eq(completion_ok, false, "failed staging reported failure")
eq(completion_path, "download_cache_unavailable", "failed staging returned a storage error")
eq(failed_workspace.cleaned, true, "failed staging cleaned its workspace")
eq(downloader._active_job, nil, "failed staging released the download job")
eq(packaged_text[33], "<p>33</p>", "failed staging did not attempt to replace a cached EPUB")
eq(#info_messages, failures_before + 1, "failed staging showed a storage error")
table.remove(info_messages)

local incomplete_full_completion_count = 0
local incomplete_full_completion_ok
local incomplete_full_completion_value
local incomplete_full = {
    book = {
        book_id = "book",
        title = "Book",
        cached_file = "/cache/book/full.epub",
        cached_full_book = "/cache/book/full.epub",
    },
    chapters = { chapter, chapter_33 },
    selected = { chapter },
    bodies = { ["22"] = "<p>22</p>" },
    assets = {},
    state = { css = "" },
    suffix = "full",
    index = 3,
    total = 2,
    failed = { "33" },
    annotation_failed_batches = 0,
    started_at = 999,
    on_complete = function(ok, value)
        incomplete_full_completion_count = incomplete_full_completion_count + 1
        incomplete_full_completion_ok = ok
        incomplete_full_completion_value = value
    end,
}
downloader:_step(incomplete_full)
eq(full_book_save_count, 0,
    "incomplete full-book download did not build a partial EPUB")
eq(stored_books.book.cached_full_book, "/cache/book/full.epub",
    "incomplete full-book download preserved the existing full cache")
eq(stored_books.book.cached_file, "/cache/book/full.epub",
    "incomplete full-book download preserved the compatibility cache alias")
eq(incomplete_full_completion_count, 1,
    "incomplete full-book completion callback count")
eq(incomplete_full_completion_ok, false,
    "incomplete full-book completion reported failure")
eq(incomplete_full_completion_value, "incomplete_full_book",
    "incomplete full-book completion reason")
eq(#info_messages, 1,
    "incomplete full-book failure was shown to the user")

local cover_base = "https://cdn.weread.qq.com/weread/cover/52/Example/"
for _, token in ipairs({ "s", "t6", "t12", "t9" }) do
    local source = cover_base .. token .. "_Example.jpg"
    local expected = cover_base .. "t9_Example.jpg"
    eq(Protocol.normalize_cover_url(source), expected, token .. " cover normalization")
    local requested_url
    downloader.client.get_binary = function(_self, url)
        requested_url = url
        return "synthetic cover bytes"
    end
    local full = {
        book = { book_id = "book", title = "Book", cover = source },
        chapters = { chapter }, selected = { chapter },
        bodies = { ["22"] = "<p>body</p>" }, assets = {}, state = { css = "" },
        suffix = "full", index = 2, total = 1, failed = {},
        annotation_failed_batches = 0, silent_completion = true, started_at = 999,
    }
    downloader:_step(full)
    eq(requested_url, expected, token .. " downloader requested upgraded cover")
    eq(saved_cover_data, "synthetic cover bytes", token .. " cover passed to EPUB packaging")
end
eq(Protocol.normalize_cover_url(nil), nil, "nil cover preserved")
eq(Protocol.normalize_cover_url(""), "", "empty cover preserved")
eq(Protocol.normalize_cover_url(false), false, "non-string cover preserved")
for _, url in ipairs({
    "https://example.com/cover.jpg",
    "https://example.com/books_Example.jpg",
    "https://example.com/small_Example.jpg",
    "https://example.com/t_Example.jpg",
    "https://example.com/twelve_Example.jpg",
}) do
    eq(Protocol.normalize_cover_url(url), url, "unrelated URL preserved: " .. url)
end

print(string.format(
    "downloader_completion_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)

-- Filesystem-level regression coverage for full-book checkpointing.
-- Run with: luajit spec/download_resume_content_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local archive_calls = {}
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return { reader_url = function(book_id) return "https://reader/" .. tostring(book_id) end }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["ffi/util"] = function()
    return {
        purgeDir = function(path)
            return os.execute("rm -rf " .. string.format("%q", path))
        end,
    }
end
package.preload["lfs"] = function()
    local function quoted(path) return string.format("%q", path) end
    return {
        attributes = function(path, attribute)
            local probe = io.popen("test -d " .. quoted(path)
                .. " && echo directory || (test -f " .. quoted(path) .. " && echo file)")
            local mode = probe:read("*l")
            probe:close()
            return attribute == "mode" and mode or (mode and { mode = mode } or nil)
        end,
        mkdir = function(path) return os.execute("mkdir -p " .. quoted(path)) end,
        dir = function(path)
            local listing = io.popen("ls -a " .. quoted(path))
            return function()
                local name = listing:read("*l")
                if not name then listing:close() end
                return name
            end
        end,
    }
end
package.preload["ffi/archiver"] = function()
    local Writer = {}
    function Writer:new() return setmetatable({}, { __index = self }) end
    function Writer:open(path)
        self.path = path
        local file = assert(io.open(path, "wb"))
        file:write("archive")
        file:close()
        return true
    end
    function Writer:setZipCompression() return true end
    function Writer:addFileFromMemory(name, data)
        archive_calls[#archive_calls + 1] = { kind = "memory", name = name, data = data }
        return true
    end
    function Writer:addPath(name, path, recursive)
        archive_calls[#archive_calls + 1] = {
            kind = "path", name = name, path = path, recursive = recursive,
        }
        return false -- KOReader's successful EOF convention.
    end
    function Writer:close() end
    return { Writer = Writer }
end

local Content = require("weread.lib.content")
local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))
local settings = {
    cache_dir = root,
    get = function(_self, _key, default) return default end,
}
local book = { book_id = "resume-book", title = "Resume Book", cache_dir = root }
local chapters = {
    { chapterUid = 11, title = "One" },
    { chapterUid = 22, title = "Two" },
}
local workspace = Content.open_full_download_workspace(settings, book)
Content.save_full_download_css(workspace, "body{color:black}")
Content.save_full_download_chapter(workspace, chapters[1], 1, "<p>first</p>")
Content.save_full_download_chapter(workspace, chapters[2], 2, "<p>second</p>")

local completed = Content.full_download_completed_chapters(workspace, chapters)
expect(completed[1] and completed[2], "checkpointed chapters were not found")
local changed_catalog = {
    chapters[1], { chapterUid = 33, title = "Changed chapter" },
}
local changed_completed = Content.full_download_completed_chapters(
    workspace, changed_catalog)
expect(changed_completed[1] and not changed_completed[2],
    "checkpoint marker did not reject a different chapter at the same index")
local restored = assert(Content.load_full_download_chapter(workspace, chapters[2], 2))
expect(restored:find("second", 1, true) ~= nil,
    "checkpointed chapter body could not be restored")
expect(Content.load_full_download_css(workspace) == "body{color:black}",
    "checkpointed stylesheet could not be restored")

local FileIdentity = require("weread.lib.book_file_identity")
book.bookVersion = 7
local source_identity = FileIdentity.capture(book)
Content.save_full_download_chapter(workspace, chapters[1], 1, "<p>first</p>", 7)
Content.save_full_download_chapter(workspace, chapters[2], 2, "<p>second</p>", 7)
expect(Content.full_download_chapter_exists(workspace, chapters[1], 1, 7), "same-version checkpoint not reusable")
expect(not Content.full_download_chapter_exists(workspace, chapters[1], 1, 8), "old-version chapter reused for a newer download")

Content.save_full_download_rendered_chapter(workspace, chapters[1], 1, "<p>rendered</p>")
local rendered = assert(Content.load_full_download_chapter(workspace, chapters[1], 1))
expect(rendered:find("first", 1, true) ~= nil and not rendered:find("rendered", 1, true),
    "footnote rendering overwrote the pristine resumable checkpoint")

local stale_rendered = assert(io.open(workspace.rendered_text_dir .. "/stale.xhtml", "wb"))
stale_rendered:write("stale")
stale_rendered:close()
Content.reset_full_download_rendered_text(workspace)
expect(not io.open(workspace.rendered_text_dir .. "/stale.xhtml", "rb"),
    "rendered chapter workspace was not reset")
expect(Content.full_download_chapter_exists(workspace, chapters[1], 1),
    "resetting rendered chapters removed the pristine checkpoint")
Content.save_full_download_rendered_chapter(workspace, chapters[1], 1, "<p>rendered first</p>")
Content.save_full_download_rendered_chapter(workspace, chapters[2], 2, "<p>rendered second</p>")
expect(Content.full_download_rendered_chapter_exists(workspace, chapters[1], 1)
    and Content.full_download_rendered_chapter_exists(workspace, chapters[2], 2),
    "rendered chapters were not available for EPUB packaging")

local first_path = Content.full_download_chapter_path(workspace, chapters[1], 1)
local truncated = assert(io.open(first_path, "wb"))
truncated:write("<!-- weread-chapter-uid: 11 -->")
truncated:close()
expect(not Content.full_download_chapter_exists(workspace, chapters[1], 1),
    "truncated checkpoint with a valid marker was accepted")
Content.save_full_download_chapter(workspace, chapters[1], 1, "<p>first</p>", 7)

local original_open = io.open
-- luacheck: push ignore 122
io.open = function(path, mode)
    local file, err = original_open(path, mode)
    if not file or path:sub(-5) ~= ".part" or mode ~= "wb" then
        return file, err
    end
    return {
        write = function(_self, data) return file:write(data) end,
        close = function()
            file:close()
            return nil, "No space left on device"
        end,
    }
end
local close_ok = pcall(Content.save_full_download_chapter,
    workspace, chapters[1], 1, "<p>must not commit</p>")
io.open = original_open
-- luacheck: pop
expect(not close_ok, "checkpoint committed after close reported a disk error")
expect(Content.full_download_chapter_exists(workspace, chapters[1], 1),
    "previous complete checkpoint was invalidated after close failure")

local output = Content.save_book_epub(settings, book, chapters,
    { __workspace_text_dir = workspace.rendered_text_dir, __source_workspace = workspace },
    "full", {}, "body{color:black}", nil, source_identity)
expect(io.open(output, "rb") ~= nil, "streamed EPUB was not committed")
local streamed_text = false
for _, call in ipairs(archive_calls) do
    if call.kind == "path" and call.name == "OEBPS/text" then
        streamed_text = call.path == workspace.rendered_text_dir and call.recursive == true
    end
end
expect(streamed_text, "EPUB writer did not stream the checkpoint text directory")
local function packaged_identity()
    for index = #archive_calls, 1, -1 do
        if archive_calls[index].name == FileIdentity.PATH then return assert(FileIdentity.decode(archive_calls[index].data)) end
    end
    error("EPUB source metadata missing")
end
expect(packaged_identity().book_version == 7, "streamed full book lost checkpoint-bound source version")
Content.save_full_download_chapter(workspace, chapters[2], 2, "<p>new second</p>", 8)
Content.save_book_epub(settings, book, chapters,
    { __workspace_text_dir = workspace.rendered_text_dir, __source_workspace = workspace },
    "full", {}, "body{color:black}", nil, source_identity)
expect(packaged_identity().book_version == 0, "mixed-version checkpoints were relabeled as a known version")

-- Raw-source receipts are tied to completed rendered checkpoints, not UID-wide
-- mutable files. A staged but unfinished replacement cannot replace old raw.
local Source = require("weread.lib.position_source")
local raw = '<html><body><p>first &amp; original</p><img src="https://example.invalid/long.jpg"/></body></html>'
local source = assert(Source.capture(book, chapters[1], raw, "web_xhtml"))
local receipt = assert(Content.store_position_source(workspace, book, chapters[1], source))
local reference = { workspace = workspace, receipt = receipt }
local resolved = assert(Source.resolve(reference, book.book_id, 11))
expect(resolved.path and not resolved.data, "staged source retained whole-chapter bytes")
expect(not Source.resolve(reference, "wrong-book", 11), "receipt crossed books")
expect(not Source.resolve(reference, book.book_id, 22), "receipt crossed chapters")
Content.save_full_download_chapter(workspace, chapters[1], 1, "<p>first</p>", 7, receipt)
expect(Content.full_download_chapter_exists(workspace, chapters[1], 1, 7), "valid source-bound checkpoint rejected")
local next_source = assert(Source.capture(book, chapters[1], raw .. " ", "web_xhtml"))
local next_receipt = assert(Content.store_position_source(workspace, book, chapters[1], next_source))
expect(next_receipt ~= receipt and Content.full_download_chapter_exists(workspace, chapters[1], 1, 7),
    "unfinished raw generation invalidated completed checkpoint")
local function write(path, data)
    local file = assert(io.open(path, "wb"))
    assert(file:write(data)); assert(file:close())
end
write(resolved.path, raw .. "corrupt")
expect(not Source.resolve(reference, book.book_id, 11), "corrupt raw passed receipt verification")
expect(not Content.full_download_chapter_exists(workspace, chapters[1], 1), "corrupt raw reused on resume")
assert(Content.store_position_source(workspace, book, chapters[1], source))
local checkpoint_path = Content.full_download_checkpoint_path(workspace, chapters[1], 1)
local file = assert(io.open(checkpoint_path, "rb"))
local checkpoint = file:read("*a"); file:close()
for _, damaged in ipairs({ checkpoint .. "position_receipt=" .. receipt .. "\n",
    checkpoint:gsub(receipt, "bad-receipt"), checkpoint:gsub("position_receipt=", "position_receipt ") }) do
    write(checkpoint_path, damaged)
    expect(not Content.full_download_chapter_exists(workspace, chapters[1], 1), "malformed receipt was treated as a legacy checkpoint")
end
write(checkpoint_path, checkpoint)
Content.save_book_epub(settings, book, chapters,
    { __workspace_text_dir = workspace.rendered_text_dir, __source_workspace = workspace },
    "full", {}, "body{color:black}", nil, source_identity)
local function last_entry(name)
    for index = #archive_calls, 1, -1 do
        if archive_calls[index].name == name then return archive_calls[index] end
    end
end
local meta = assert(Source.decode_metadata(assert(last_entry(Source.meta_path(11))).data))
expect(meta.capture_id == receipt and meta.render_path == "OEBPS/text/chapter-001.xhtml", "EPUB used unfinished raw generation")
expect(last_entry(Source.raw_path(source.raw_sha256)).path == resolved.path, "EPUB did not stream original source")
expect(last_entry(Source.path_meta_path(meta.render_path)).data == last_entry(Source.meta_path(11)).data, "member alias disagrees with UID metadata")
local first_id = packaged_identity().file_id
Content.save_full_download_chapter(workspace, chapters[1], 1, "<p>first</p>", 7, next_receipt)
Content.save_book_epub(settings, book, chapters,
    { __workspace_text_dir = workspace.rendered_text_dir, __source_workspace = workspace },
    "full", {}, "body{color:black}", nil, source_identity)
expect(packaged_identity().file_id ~= first_id, "same rendered chapter with new raw reused file identity")
-- A legacy checkpoint must not pick up raw left behind by another generation.
Content.save_full_download_chapter(workspace, chapters[1], 1, "<p>first</p>", 7)
archive_calls = {}
Content.save_book_epub(settings, book, chapters,
    { __workspace_text_dir = workspace.rendered_text_dir, __source_workspace = workspace },
    "full", {}, "body{color:black}", nil, source_identity)
expect(not last_entry(Source.meta_path(11)), "legacy checkpoint guessed source from leftover raw")
-- Direct single-chapter packaging also binds original bytes independently of
-- rendered content and exposes both archive aliases.
Content.save_chapter_epub(settings, book, chapters[1], "<p>same rendered</p>", {}, nil, source_identity, source)
local chapter_id = packaged_identity().file_id
expect(assert(Source.decode_metadata(last_entry(Source.meta_path(11)).data)).capture_id == receipt,
    "single-chapter source lost")
Content.save_chapter_epub(settings, book, chapters[1], "<p>same rendered</p>", {}, nil, source_identity, next_source)
expect(packaged_identity().file_id ~= chapter_id, "single-chapter raw change reused identity")

Content.cleanup_download_workspace(workspace)
expect(not io.open(workspace.text_dir .. "/chapter-001.xhtml", "rb"),
    "successful cleanup did not remove the resumable workspace")

print(("download_resume_content_spec: %d checks"):format(checks))

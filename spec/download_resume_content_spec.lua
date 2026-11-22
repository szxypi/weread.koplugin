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
local owner_scope={vid='12345678',epoch=1}
settings.get_auth_scope=function() return owner_scope end
settings.auth_scope_matches=function(_,value) return value==owner_scope end
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
local guarded_path=Content.save_chapter_epub(settings, book, chapters[1], "<p>same rendered</p>", {}, nil, source_identity, next_source)
expect(packaged_identity().file_id ~= chapter_id, "single-chapter raw change reused identity")
local prior=assert(io.open(guarded_path,'wb'));prior:write('previous-book');prior:close()
local allowed,reason=pcall(Content.save_chapter_epub,settings,book,chapters[1],'<p>new body</p>',{},nil,
    source_identity,next_source,nil,function() return false end)
local retained=assert(io.open(guarded_path,'rb'));local bytes=retained:read('*a');retained:close()
expect(not allowed and reason=='chapter_prefetch/session_changed' and bytes=='previous-book'
    and not io.open(guarded_path..'.part','rb'),'failed publication guard changed an existing book or left a partial file')

-- Individual native styles survive resume and footnote rendering, while a
-- changed or missing style invalidates its chapter before EPUB publication.
local Crypto=require('weread.lib.crypto')
local first_css,second_css='p{color:black}','p{color:gray}'
local first_hash,second_hash=Crypto.sha256_hex(first_css),Crypto.sha256_hex(second_css)
local empty_style=Content.stage_full_download_style(workspace,'')
expect(empty_style==Crypto.sha256_hex('') and Content.stage_full_download_style(workspace,'')==empty_style,
    'empty chapter stylesheet could not be reused')
local image_bytes='\137PNG\r\n\26\nsynthetic image'
local image_name='eink-'..Crypto.sha256_hex(image_bytes)..'.png'
local image_path=workspace.asset_dir..'/'..image_name
write(image_path,image_bytes)
local image_receipt=Content.stage_full_download_assets(workspace,
    {{href='images/'..image_name,path=image_path,media_type='image/png'}})
local empty_receipt=Content.stage_full_download_assets(workspace,{})
local second_source=assert(Source.capture(book,chapters[2],'<p>second original</p>','web_xhtml'))
local second_receipt=assert(Content.store_position_source(workspace,book,chapters[2],second_source))
expect(Content.stage_full_download_style(workspace,first_css)==first_hash
    and Content.stage_full_download_style(workspace,second_css)==second_hash,'stylesheet staging changed its digest')
Content.save_full_download_chapter(workspace,chapters[1],1,'<p>first styled</p>',7,receipt,first_hash,image_receipt)
Content.save_full_download_chapter(workspace,chapters[2],2,'<p>second styled</p>',7,second_receipt,second_hash,empty_receipt)
expect(Content.full_download_chapter_exists(workspace,chapters[1],1,7)
    and Content.full_download_chapter_exists(workspace,chapters[2],2,7),'per-chapter style checkpoints were not reusable')
owner_scope={vid='87654321',epoch=1}
local other_workspace=Content.open_full_download_workspace(settings,book)
expect(not Content.full_download_chapter_exists(other_workspace,chapters[1],1,7)
    and not Content.full_download_asset_repairable(other_workspace,chapters[1],1,image_name,7),
    'another account reused or repaired a native checkpoint')
owner_scope={vid='12345678',epoch=2}
local relogged_workspace=Content.open_full_download_workspace(settings,book)
expect(Content.full_download_chapter_exists(relogged_workspace,chapters[1],1,7),
    'same-account login could not resume its native checkpoint')
Content.save_full_download_rendered_chapter(workspace,chapters[1],1,'<p>first rendered</p>')
Content.save_full_download_rendered_chapter(workspace,chapters[2],2,'<p>second rendered</p>')
local function read_all(path)
    local f=assert(io.open(path,'rb'));local value=f:read('*a');assert(f:close());return value
end
local rendered_first=read_all(Content.full_download_rendered_chapter_path(workspace,chapters[1],1))
local rendered_second=read_all(Content.full_download_rendered_chapter_path(workspace,chapters[2],2))
local orphan_bytes='\137PNG\r\n\26\norphaned native image'
local orphan_name='eink-'..Crypto.sha256_hex(orphan_bytes)..'.png'
write(workspace.asset_dir..'/'..orphan_name,orphan_bytes)
local web_bytes='\137PNG\r\n\26\nweb image with a native-looking name'
local web_name='eink-'..Crypto.sha256_hex(web_bytes)..'.png'
write(workspace.asset_dir..'/'..web_name,web_bytes)
Content.save_full_download_rendered_chapter(workspace,chapters[2],2,'<img src="../images/'..web_name..'"/>')
local short_rendered=read_all(Content.full_download_rendered_chapter_path(workspace,chapters[2],2))
local image_offset=assert(short_rendered:find(web_name,1,true))
Content.save_full_download_rendered_chapter(workspace,chapters[2],2,
    string.rep('x',65506-image_offset)..'<img src="../images/'..web_name..'"/>')
local selected=Content.full_download_workspace_assets(workspace,chapters,'')
local selected_names={}
for _,asset in ipairs(selected) do selected_names[asset.href]=true end
expect(selected_names['images/'..image_name] and selected_names['images/'..web_name]
    and not selected_names['images/'..orphan_name],
    'packaging lost a referenced image or retained an orphan native image')
Content.save_full_download_rendered_chapter(workspace,chapters[2],2,'<p>second rendered</p>')
selected_names={}
for _,asset in ipairs(Content.full_download_workspace_assets(workspace,chapters,'body{background:url(images/'..web_name..')}')) do
    selected_names[asset.href]=true
end
expect(selected_names['images/'..web_name] and not selected_names['images/'..orphan_name],
    'common stylesheet image was not retained or orphan image was included')
selected_names={}
local encoded_native=web_name:gsub('^eink%-','eink%%2d')
for _,asset in ipairs(Content.full_download_workspace_assets(workspace,chapters,'body{background:url(images/'..encoded_native..')}')) do
    selected_names[asset.href]=true
end
expect(selected_names['images/'..web_name], 'encoded Web image with a native-like name was excluded')
expect(rendered_first:find('../eink-style-'..first_hash..'.css',1,true)
    and rendered_second:find('../eink-style-'..second_hash..'.css',1,true),
    'footnote rendering lost chapter-specific styles')
archive_calls={}
local full_path=Content.save_book_epub(settings,book,chapters,
    {__workspace_text_dir=workspace.rendered_text_dir,__source_workspace=workspace},'full',
    Content.full_download_workspace_assets(workspace,chapters,''),nil,nil,source_identity)
local first_style=assert(last_entry('OEBPS/eink-style-'..first_hash..'.css'))
local second_style=assert(last_entry('OEBPS/eink-style-'..second_hash..'.css'))
local opf=assert(last_entry('OEBPS/content.opf')).data
expect(first_style.path==workspace.style_dir..'/eink-'..first_hash..'.css'
    and second_style.path==workspace.style_dir..'/eink-'..second_hash..'.css'
    and opf:find('eink-style-'..first_hash..'.css',1,true) and opf:find('eink-style-'..second_hash..'.css',1,true),
    'EPUB failed to include chapter-specific styles in the manifest')
expect(not opf:find(orphan_name,1,true) and not last_entry('OEBPS/images/'..orphan_name),
    'orphan image was included in the EPUB')
local packaged_images=assert(last_entry('OEBPS/images')).path
expect(packaged_images==workspace.path..'/package-images'
    and read_all(packaged_images..'/'..image_name)==image_bytes
    and not io.open(packaged_images..'/'..orphan_name,'rb'),
    'the archive still streamed the unfiltered image directory')
write(full_path,'prior-full-book')
assert(os.execute('rm -rf '..string.format('%q',packaged_images)))
write(packaged_images,'conflicting file')
expect(not pcall(Content.full_download_workspace_assets,workspace,chapters,'')
    and read_all(full_path)=='prior-full-book',
    'a conflicting package staging path replaced the previous book')
assert(os.remove(packaged_images))
-- The plain-Lua test has no hard-link function, exercising the copy fallback.
-- luacheck: push ignore 122
io.open=function(path,mode)
    local opened,err=original_open(path,mode)
    if opened and mode=='wb' and path:sub(1,#packaged_images+1)==packaged_images..'/' then
        return {write=function() return nil,'disk full' end,close=function() return opened:close() end}
    end
    return opened,err
end
local stage_ok=pcall(Content.full_download_workspace_assets,workspace,chapters,'')
io.open=original_open
-- luacheck: pop
expect(not stage_ok and read_all(full_path)=='prior-full-book',
    'failed image staging replaced the previous book')
expect(not pcall(Content.save_book_epub,settings,book,chapters,
    {__workspace_text_dir=workspace.rendered_text_dir,__source_workspace=workspace},'full',{},nil,nil,source_identity)
    and read_all(full_path)=='prior-full-book','EPUB omitted a required native image')
local guarded=pcall(Content.save_book_epub,settings,book,chapters,
    {__workspace_text_dir=workspace.rendered_text_dir,__source_workspace=workspace},'full',
    Content.full_download_workspace_assets(workspace),nil,nil,source_identity,
    nil,nil,function() return false end)
expect(not guarded and read_all(full_path)=='prior-full-book' and not io.open(full_path..'.part','rb'),
    'failed full-book account guard replaced the previously downloaded book')
write(first_style.path,'corrupt')
expect(not Content.full_download_chapter_exists(workspace,chapters[1],1)
    and not Content.full_download_rendered_chapter_exists(workspace,chapters[1],1),
    'corrupt stylesheet was accepted for resume or publication')
expect(not pcall(Content.save_book_epub,settings,book,chapters,
    {__workspace_text_dir=workspace.rendered_text_dir,__source_workspace=workspace},'full',{},nil,nil,source_identity),
    'EPUB was published with a corrupt chapter stylesheet')
expect(Content.full_download_style_repairable(workspace,chapters[1],1,first_hash,7)
    and not Content.full_download_style_repairable(workspace,chapters[1],1,first_hash,8)
    and not Content.full_download_style_repairable(workspace,chapters[2],2,first_hash,7),
    'stylesheet repair was not limited to the original chapter and source version')
expect(not pcall(Content.stage_full_download_style,workspace,first_css),'unproven style replacement was allowed')
expect(Content.stage_full_download_style(workspace,first_css,function(digest)
    return Content.full_download_style_repairable(workspace,chapters[1],1,digest,7)
end)==first_hash and read_all(first_style.path)==first_css,'proven stylesheet could not be repaired')
write(image_path,'corrupt image')
expect(Content.full_download_workspace_used_asset_names(workspace)[image_name],
    'a damaged native asset name was available for reuse by another source')
expect(not Content.full_download_chapter_exists(workspace,chapters[1],1)
    and not Content.full_download_rendered_chapter_exists(workspace,chapters[1],1)
    and Content.full_download_chapter_exists(workspace,chapters[2],2),
    'damaged native image was accepted or invalidated an unrelated chapter')
expect(Content.full_download_asset_repairable(workspace,chapters[1],1,image_name,7)
    and not Content.full_download_asset_repairable(workspace,chapters[1],1,image_name,8)
    and not Content.full_download_asset_repairable(workspace,chapters[2],2,image_name,7),
    'asset repair was not limited to the original chapter and source version')
write(image_path,image_bytes)
local asset_receipt_path=workspace.asset_receipt_dir..'/assets-'..image_receipt..'.txt'
local saved_asset_receipt=read_all(asset_receipt_path)
write(asset_receipt_path,saved_asset_receipt..image_name..'\n')
expect(not Content.full_download_chapter_exists(workspace,chapters[1],1),
    'corrupted asset receipt was accepted')
expect(not Content.full_download_asset_repairable(workspace,chapters[1],1,image_name,7),
    'corrupt asset receipt authorized a replacement')
expect(Content.stage_full_download_assets(workspace,
    {{href='images/'..image_name,path=image_path,media_type='image/png'}})==image_receipt
    and read_all(asset_receipt_path)==saved_asset_receipt,'freshly verified assets could not repair their receipt')
os.remove(image_path)
expect(not Content.full_download_chapter_exists(workspace,chapters[1],1),'missing native image was accepted')
write(image_path,image_bytes)
local styled_checkpoint=read_all(checkpoint_path)
write(checkpoint_path,styled_checkpoint..'style_sha256='..first_hash..'\n')
expect(not Content.full_download_chapter_exists(workspace,chapters[1],1),'duplicate style identity was accepted')
write(checkpoint_path,styled_checkpoint:gsub('assets_sha256='..image_receipt..'\n',''))
expect(not Content.full_download_chapter_exists(workspace,chapters[1],1),'missing native asset receipt was accepted')
write(checkpoint_path,styled_checkpoint:gsub('position_receipt='..receipt..'\n',''))
expect(not Content.full_download_chapter_exists(workspace,chapters[1],1),
    'native checkpoint without original position source was accepted')
write(checkpoint_path,styled_checkpoint:gsub('native_owner_sha256='..workspace.native_owner..'\n',''))
expect(not Content.full_download_chapter_exists(workspace,chapters[1],1),
    'native checkpoint without an owner was accepted')
write(checkpoint_path,styled_checkpoint:gsub('style_sha256='..first_hash..'\n',''))
expect(not Content.full_download_chapter_exists(workspace,chapters[1],1)
    and not Content.full_download_rendered_chapter_exists(workspace,chapters[1],1),
    'missing native stylesheet identity was treated as a legacy chapter')
write(checkpoint_path,styled_checkpoint)
write(Content.full_download_rendered_chapter_path(workspace,chapters[1],1),rendered_first:gsub(first_hash,second_hash))
expect(not Content.full_download_rendered_chapter_exists(workspace,chapters[1],1),
    'rendered chapter accepted another chapter stylesheet')

-- Web image checkpoints are account-bound and detect missing or modified
-- files, while old checkpoints remain readable when images are not required.
local WebImages=require('weread.lib.web_image_receipt')
local web_chapter={chapterUid=33,title='Web'}
local web_file='共享 图片.png'
local web_path=workspace.asset_dir..'/'..web_file
local web_data='\137PNG\r\n\26\n'..string.rep('a',70000)
write(web_path,web_data)
local web_assets={{href='images/'..web_file,path=web_path,media_type='image/png'}}
local web_digest=WebImages.stage(workspace,web_assets)
local valid,web_names=WebImages.verify(workspace,web_digest)
expect(valid and #web_names==1 and web_names[1]==web_file,'web image receipt rejected a valid Unicode image')
Content.save_full_download_chapter(workspace,web_chapter,3,'<p>web</p>',7,nil,nil,nil,web_digest)
Content.save_full_download_rendered_chapter(workspace,web_chapter,3,'<p>web</p>')
expect(Content.full_download_chapter_exists(workspace,web_chapter,3,7,true),
    'complete web image checkpoint was not reusable')
local web_checkpoint_path=Content.full_download_checkpoint_path(workspace,web_chapter,3)
local web_checkpoint=read_all(web_checkpoint_path)
write(web_checkpoint_path,web_checkpoint..'web_images_digest='..web_digest..'\n')
expect(not Content.full_download_chapter_exists(workspace,web_chapter,3,7,true),
    'duplicate web image receipt was accepted')
write(web_checkpoint_path,web_checkpoint:gsub('web_owner_sha256='..workspace.native_owner..'\n',''))
expect(not Content.full_download_chapter_exists(workspace,web_chapter,3,7,true),
    'web image receipt without an owner was accepted')
write(web_checkpoint_path,web_checkpoint)
write(Content.full_download_rendered_chapter_path(workspace,chapters[1],1),rendered_first)
local full_chapters={chapters[1],chapters[2],web_chapter}
local stale_name='orphan & image.png'
local stale_path=workspace.asset_dir..'/'..stale_name
write(stale_path,'\137PNG\r\n\26\nold image')
local old_web_digest=WebImages.stage(workspace,{{href='images/'..stale_name,path=stale_path,media_type='image/png'}})
write(stale_path,'\137PNG\r\n\26\nchanged old image')
local old_valid,old_names=WebImages.names(workspace,old_web_digest)
expect(old_valid and #old_names==1 and old_names[1]==stale_name and not WebImages.verify(workspace,old_web_digest),
    'old receipt could not identify an image after its contents changed')
local unknown_name='untracked.png'
write(workspace.asset_dir..'/'..unknown_name,'\137PNG\r\n\26\nuntracked')
local function selected_web(css)
    local names={}
    for _,asset in ipairs(Content.full_download_workspace_assets(workspace,full_chapters,css or '')) do
        names[asset.href]=true
    end
    return names
end
local filtered=selected_web()
expect(not filtered['images/'..stale_name] and filtered['images/'..web_file]
    and filtered['images/'..unknown_name],'known stale or unknown Web images were handled incorrectly')
Content.save_full_download_rendered_chapter(workspace,web_chapter,3,
    string.rep('x',65520)..'<img src="../images/orphan%20%26%20image.png"/>')
expect(selected_web()['images/'..stale_name], 'percent-encoded reference across chunks lost its image')
Content.save_full_download_rendered_chapter(workspace,web_chapter,3,
    '<img src="../images/orphan &amp; image.png"/>')
expect(selected_web()['images/'..stale_name], 'entity-encoded reference lost its image')
local entity_name='literal &quot; image.png'
local entity_path=workspace.asset_dir..'/'..entity_name
write(entity_path,'\137PNG\r\n\26\nentity')
WebImages.stage(workspace,{{href='images/'..entity_name,path=entity_path,media_type='image/png'}})
Content.save_full_download_rendered_chapter(workspace,web_chapter,3,
    '<img src="../images/literal &amp;quot; image.png"/>')
expect(selected_web()['images/'..entity_name], 'nested literal entity was decoded twice and lost its image')
Content.save_full_download_rendered_chapter(workspace,web_chapter,3,'<p>web &#160;</p>')
expect(selected_web()['images/'..stale_name], 'ambiguous entity did not preserve older images')
Content.save_full_download_rendered_chapter(workspace,web_chapter,3,'<p>web</p>')
expect(selected_web('p{background:url("images/orphan%20%26%20image.png")}')['images/'..stale_name],
    'CSS reference lost an older image')
expect(selected_web('p{background:url("images/orphan\\20 image.png")}')['images/'..stale_name],
    'ambiguous CSS escape did not preserve older images')
expect(selected_web('@import url("other.css")')['images/'..stale_name],
    'imported stylesheet did not preserve older images')
local old_receipt_path=workspace.web_asset_receipt_dir..'/images-'..old_web_digest..'.txt'
local old_receipt=read_all(old_receipt_path)
write(old_receipt_path,old_receipt..'corrupt\n')
expect(selected_web()['images/'..stale_name], 'a corrupt old receipt caused an unknown image to be removed')
write(old_receipt_path,old_receipt)
local bulk={}
for i=1,513 do
    local name=string.format('bulk-%04d.png',i)
    local hex=name:gsub('.',function(c) return string.format('%02x',c:byte()) end)
    bulk[#bulk+1]=hex..':1:'..string.rep('0',64)..'\n'
end
local bulk_raw=table.concat(bulk)
local bulk_path=workspace.web_asset_receipt_dir..'/images-'..Crypto.sha256_hex(bulk_raw)..'.txt'
write(bulk_path,bulk_raw)
expect(selected_web()['images/'..stale_name], 'large history was not handled conservatively')
assert(os.remove(bulk_path))
Content.save_full_download_chapter(workspace,web_chapter,3,'<p>legacy</p>',7)
local legacy_names=selected_web()
expect(legacy_names['images/'..stale_name] and legacy_names['images/'..orphan_name],
    'legacy Web checkpoint did not preserve older images')
Content.save_full_download_chapter(workspace,web_chapter,3,'<p>web</p>',7,nil,nil,nil,web_digest)
local without_web={}
for _,asset in ipairs(Content.full_download_workspace_assets(workspace)) do
    if asset.href~='images/'..web_file then without_web[#without_web+1]=asset end
end
write(full_path,'previous book')
expect(not pcall(Content.save_book_epub,settings,book,full_chapters,
    {__workspace_text_dir=workspace.rendered_text_dir,__source_workspace=workspace},'full',without_web,nil,nil,source_identity)
    and read_all(full_path)=='previous book','EPUB was published without a required web image')
archive_calls={}
Content.save_book_epub(settings,book,full_chapters,
    {__workspace_text_dir=workspace.rendered_text_dir,__source_workspace=workspace},'full',
    Content.full_download_workspace_assets(workspace),nil,nil,source_identity)
expect(assert(last_entry('OEBPS/content.opf')).data:find('images/'..web_file,1,true),
    'EPUB manifest omitted a verified web image')
write(web_path,web_data:sub(1,-2)..'b')
expect(not Content.full_download_chapter_exists(workspace,web_chapter,3,7,true),
    'modified web image was accepted')
write(web_path,web_data)
os.remove(web_path)
expect(not Content.full_download_chapter_exists(workspace,web_chapter,3,7,true),
    'missing web image was accepted')
write(web_path,web_data)
owner_scope={vid='87654321',epoch=3}
local switched_workspace=Content.open_full_download_workspace(settings,book)
expect(not Content.full_download_chapter_exists(switched_workspace,web_chapter,3,7,true),
    'web image checkpoint crossed accounts')
owner_scope={vid='12345678',epoch=4}
local same_workspace=Content.open_full_download_workspace(settings,book)
expect(Content.full_download_chapter_exists(same_workspace,web_chapter,3,7,true),
    'same-account login could not restore web image checkpoint')
local web_receipt=workspace.web_asset_receipt_dir..'/images-'..web_digest..'.txt'
local saved_web_receipt=read_all(web_receipt)
write(web_receipt,saved_web_receipt..'bad\n')
expect(not Content.full_download_chapter_exists(workspace,web_chapter,3,7,true),
    'damaged web image receipt was accepted')
expect(WebImages.stage(workspace,web_assets)==web_digest and WebImages.verify(workspace,web_digest),
    'verified web images could not restore their receipt')
Content.save_full_download_chapter(workspace,web_chapter,3,'<p>legacy</p>',7)
expect(Content.full_download_chapter_exists(workspace,web_chapter,3,7)
    and not Content.full_download_chapter_exists(workspace,web_chapter,3,7,true),
    'legacy web checkpoint did not respect the image requirement')
local empty_web=WebImages.stage(workspace,{})
expect(WebImages.verify(workspace,empty_web),'empty web image receipt was rejected')

Content.cleanup_download_workspace(workspace)
expect(not io.open(workspace.text_dir .. "/chapter-001.xhtml", "rb"),
    "successful cleanup did not remove the resumable workspace")

print(("download_resume_content_spec: %d checks"):format(checks))

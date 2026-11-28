-- Packaged candidate, native archive/DOM/ReaderUI, fail-closed local HTTP mock.
local Source = require('weread.lib.position_source')
local Coordinates = require('weread.lib.source_coordinates')
local Identity = require('weread.lib.book_file_identity')
local M = {}
local report = { public_network_used = false, production_account_writes_attempted = 0,
    progress_mapping_enabled = false, wire_progress_write_verified = false }

function M.reader(reader, flush, evidence)
    local doc = reader.document
    local book_id = assert(reader.weread:detectWeReadBook())
    local source = assert(Source.read_document(doc, book_id, 1))
    assert(source.book_version == 7 and source.format == 'web_xhtml', 'source scope/version')
    assert(source.raw:find('https://weread.qq.com/mock/illustration.png', 1, true), 'rewritten image URL captured as original')
    local rendered = assert(doc:getDocumentFileContent(source.render_path))
    assert(not rendered:find('https://weread.qq.com/mock/illustration.png', 1, true)
        and rendered:find('../images/', 1, true), 'image rewrite not exercised')
    assert(assert(Source.read_document(doc, book_id, nil, source.render_path)).capture_id == source.capture_id, 'path alias differs')
    local map = assert(Coordinates.build(source.raw))
    local position = assert(map:locate('这是第1章的第16段。我们沿着小路慢慢前行'))
    -- Keep this probe inside a single paragraph. Normalized anchors crossing
    -- blocks need the chapter DOM walk before production integration.
    local target_co = position.co + 12
    local anchor = assert(map:anchor(target_co))
    local hits = assert(doc:findAllText(anchor.text, true, 0, 10, false, 0))
    assert(#hits == 1, 'reverse anchor is not unique in native DOM')
    doc:clearSelection()
    local target = hits[1].start
    for _i = 1, anchor.point_offset do target = assert(doc:getNextVisibleChar(target)) end
    local prefix, count = {}, 0
    for character in anchor.text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        if count >= anchor.point_offset then break end
        prefix[#prefix + 1], count = character, count + 1
    end
    local extracted = assert(doc:getTextFromXPointers(hits[1].start, target))
    doc:clearSelection()
    assert(extracted == table.concat(prefix), 'scalar walk diverged from anchor prefix')
    reader.rolling:onGotoPage(1)
    flush()
    local before = doc:getCurrentPage()
    assert(reader:handleEvent(require('ui/event'):new('GotoXPointer', target)), 'native jump not handled')
    flush()
    assert(doc:isXPointerInCurrentPage(target), 'source-coordinate target not visible after native jump')
    local page = doc:getCurrentPage()
    assert(before == 1 and page > 1, 'probe did not actually change pages')
    require('ui/uimanager'):forceRePaint()
    require('device').screen:shot(evidence .. '/source-coordinate-page.png')
    report.reader = { raw_bytes = #source.raw, co = target_co, point_offset = anchor.point_offset,
        target_page = page, previous_page = before, total_pages = doc:getPageCount(),
        exact_prefix_verified = true, target_visible = true, raw_before_images = true,
        file_version = source.book_version, file_id = source.file_id }
    local dom,dom_reason = require('weread.lib.source_dom').open(doc,book_id,1)
    assert(dom,dom_reason)
    local dom_point = assert(dom:locate(target_co))
    assert(assert(dom:capture(dom_point.xpointer)).co == target_co, 'downloaded source/DOM roundtrip changed co')
    report.reader.chapter_dom_roundtrip = true
    -- The current single-chapter download uses the same production entry as a
    -- full-book source target, including transformed images and footnotes.
    reader.rolling:onGotoPage(before)
    flush()
    local bound={book_id=tostring(book_id),chapter_uid='1',chapter_offset=target_co,
        basis='filtered_xhtml_utf16',upload_verified=false}
    for _,key in ipairs({'file_id','book_version','raw_sha256','render_path'}) do bound[key]=source[key] end
    local done,navigated,why
    assert(reader.weread:openSourcePosition(bound,function(value,reason) done,navigated,why=true,value,reason end))
    local socket=require('socket')
    local deadline=socket.gettime()+15
    local manager=require('ui/uimanager')
    manager:setInputTimeout(0)
    repeat
        manager:handleInput()
        assert(socket.gettime()<deadline,'single-chapter source navigation timed out')
        require('ffi/util').usleep(10000)
    until done
    assert(navigated,why)
    assert(navigated.chapter_offset==target_co and doc:isXPointerInCurrentPage(dom_point.xpointer),
        'production single-chapter target changed coordinate or viewport')
    assert(reader.weread.source_position:current().retained_source_target,'single-chapter source target was not retained')
    report.reader.production_source_navigation=true
    reader.rolling:onGotoPage(before)
    flush()
    print('PASS: embedded original -> filtered UTF16 co -> unique DOM anchor -> scalar XPointer -> native visible page')
end

function M.full(path, book_id, chapters, evidence, client)
    local doc = assert(require('document/documentregistry'):openDocument(path))
    assert(doc:loadDocument(), 'downloaded full EPUB failed to open')
    doc:render()
    local root = Identity.read_document(doc, book_id)
    local checked, footnotes = 0, 0
    for _, chapter in ipairs(chapters) do
        local source = assert(Source.read_document(doc, book_id, chapter.chapterUid))
        assert(source.file_id == root.file_id and source.book_version == root.book_version, 'full EPUB scope mismatch')
        local rendered = assert(doc:getDocumentFileContent(source.render_path))
        assert(source.raw:find('https://weread.qq.com/mock/illustration.png', 1, true)
            and not rendered:find('https://weread.qq.com/mock/illustration.png', 1, true), 'full EPUB original image URL lost')
        assert(source.raw:find('<aside id="note1"', 1, true), 'original footnote definition lost')
        if rendered:find('class="wr-footnotes"', 1, true) then footnotes = footnotes + 1 end
        assert(assert(Source.read_document(doc, book_id, nil, source.render_path)).capture_id == source.capture_id, 'full member alias differs')
        local map = assert(Coordinates.build(source.raw), 'full original source cannot build coordinate map')
        if checked == 0 or checked == #chapters-1 then
            local dom,dom_reason = require('weread.lib.source_dom').open(doc,book_id,chapter.chapterUid)
            assert(dom,dom_reason)
            local point = assert(map:locate('这是第' .. tostring(chapter.chapterUid) .. '章的第16段。我们沿着小路慢慢前行'))
            local located = assert(dom:locate(point.co))
            assert(assert(dom:capture(located.xpointer)).co == point.co, 'transformed full chapter DOM roundtrip changed co')
        end
        checked = checked + 1
    end
    assert(checked == 6 and footnotes == 6, 'full original/footnote transform coverage missing')
    report.full = { chapters = checked, raw_before_footnotes = footnotes, raw_before_images = checked,
        file_version = root.book_version, file_id = root.file_id, background_packaging = true, transformed_chapter_dom_roundtrips = 2 }
    doc:close()
    -- The synchronous range and background-prefetch worker also capture raw
    -- sources when image downloads are disabled.
    local settings = client.settings
    local cache = settings:get('cache', {})
    local previous_images = cache.download_book_images
    cache.download_book_images = false
    settings:set('cache', cache)
    local book = { book_id = book_id, bookVersion = 7, title = 'Source routes', chapters = chapters }
    local range = require('weread.lib.content').fetch_chapters_epub(client, settings, book,
        { chapters[2], chapters[3] }, { suffix = 'source-routes' })
    local range_doc = assert(require('document/documentregistry'):openDocument(range))
    assert(range_doc:loadDocument(false))
    assert(Source.read_document(range_doc, book_id, chapters[2].chapterUid))
    assert(Source.read_document(range_doc, book_id, chapters[3].chapterUid))
    range_doc:close()
    local prefetch = require('weread.lib.chapter_prefetch_worker').run(settings, client, book, chapters[4], {
        emit = function() end, checkCancelled = function() end, sleep = function() end,
    })
    local prefetch_doc = assert(require('document/documentregistry'):openDocument(prefetch.path))
    assert(prefetch_doc:loadDocument(false))
    local prefetch_source = assert(Source.read_document(prefetch_doc, book_id, chapters[4].chapterUid))
    assert(prefetch_source.raw:find('<aside id="note1"', 1, true), 'prefetch captured transformed footnotes')
    prefetch_doc:close()
    cache.download_book_images = previous_images
    settings:set('cache', cache)
    report.extra_routes = { synchronous_range_chapters = 2, prefetch_worker_chapters = 1, images_disabled = true }
    local file = assert(io.open(evidence .. '/source-binding.json', 'wb'))
    assert(file:write(client:json_encode(report))); assert(file:close())
    print('PASS: six resumed-checkpoint receipts -> background EPUB package -> native archive; original image/footnote bytes retained')
end
return M

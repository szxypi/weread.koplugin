-- Verify displayed full-book cache status without exposing titles or content.
return function(input,host,reader,pump)
    local UI=require('ui/uimanager')
    local tr=require('weread.lib.plugin_util').tr
    local before=reader.document:getXPointer()
    local file=reader.document.file
    local book=assert(host.settings:get_book(input.book_id))
    local chapters=assert(host:ensureChaptersLoaded(book))
    local expected={}
    for _,item in ipairs(input.full_manifest) do
        assert(not expected[item.chapter_uid]);expected[item.chapter_uid]=true
    end
    local function clean()
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do
            UI:close(UI:getTopmostVisibleWidget())
        end
    end
    clean();host:showChapterList(book)
    pump(function() return host._chapter_list_view~=nil end)
    local view=assert(host._chapter_list_view)
    local seen={}
    for _,item in ipairs(view.chapters) do
        local chapter=item.source
        local uid=chapter and tostring(chapter.chapterUid or chapter.chapterId)
        if expected[uid] then
            assert(not seen[uid] and item.status==tr('Cached'),'full-book chapter status missing')
            seen[uid]=true
        end
    end
    for uid in pairs(expected) do assert(seen[uid],'full-book chapter absent from catalog') end
    host:showChapterDownloadSelection(book,chapters)
    local menu=assert(UI:getTopmostVisibleWidget())
    local index,verified=0,0
    for _,item in ipairs(menu.item_table) do
        if not item.separator then
            index=index+1
            local chapter=assert(chapters[index])
            local uid=tostring(chapter.chapterUid or chapter.chapterId)
            if expected[uid] then
                assert(item.mandatory==tr('Cached'),'full-book download selection status missing')
                verified=verified+1
            end
        end
    end
    assert(index==#chapters and verified==#input.full_manifest,'full-book download selection incomplete')
    clean();assert(reader.document.file==file and reader.document:getXPointer()==before,'status inspection changed reading position')
    return true
end

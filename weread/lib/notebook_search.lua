-- Search validated account-local notebook snapshots without network or writes.
local Marks=require('weread.lib.my_cloud_marks')
local Search=require('weread.lib.shelf_search')
local Protocol=require('weread.lib.protocol')
local M={MAX_RESULTS=200}

local function preview(value)
    value=value:gsub('[%z%c]',' ')
    local short=Protocol.utf8_substr(value,80)
    return #short<#value and short..'…' or short
end

function M.search(catalog,marks,thoughts,query)
    assert(type(catalog)=='table' and type(marks)=='table' and type(thoughts)=='table', 'notebook_search/input')
    local needle=assert(Search.prepare(query),'notebook_search/query')
    local mark_ids=assert(marks:list_ids(),'notebook_search/store')
    local thought_ids=assert(thoughts:list_ids(),'notebook_search/store')
    local marked,reviewed={},{}
    for _,id in ipairs(mark_ids) do marked[id]=true end
    for _,id in ipairs(thought_ids) do reviewed[id]=true end
    local books,seen,not_cached={}, {}, 0
    for _,book in ipairs(catalog) do
        local id=type(book)=='table' and book.bookId
        if Marks.display_id(id) and not seen[id] then
            seen[id]=true
            if not marked[id] then not_cached=not_cached+1 end
            if not reviewed[id] then not_cached=not_cached+1 end
            if marked[id] or reviewed[id] then books[#books+1]=id end
        end
    end
    local extras={}
    for _,ids in ipairs({mark_ids,thought_ids}) do
        for _,id in ipairs(ids) do if not seen[id] then seen[id]=true;extras[#extras+1]=id end end
    end
    table.sort(extras);for _,id in ipairs(extras) do books[#books+1]=id end
    local out={items={},available=#mark_ids+#thought_ids,checked=0,failed=0,not_cached=not_cached,truncated=false}
    for _,id in ipairs(books) do
        local chapters={}
        for _,source in ipairs({{kind='marks',store=marks,exists=marked[id]},
                                {kind='thoughts',store=thoughts,exists=reviewed[id]}}) do
            if source.exists then
                out.checked=out.checked+1
                local snapshot=source.store:read(id)
                if not snapshot then out.failed=out.failed+1 else
                    if source.kind=='marks' then
                        for _,chapter in ipairs(snapshot.chapters) do chapters[chapter.chapterUid]=chapter.title end
                    end
                    for _,row in ipairs(source.kind=='marks' and snapshot.updated or snapshot.reviews) do
                        local chapter=row.chapterName
                        if not chapter or chapter=='' then chapter=chapters[row.chapterUid] end
                        local matched
                        for _,value in ipairs({row.content or '',row.markText or '',row.abstract or '',chapter or ''}) do
                            if Search.contains(value,needle) then matched=value;break end
                        end
                        if matched then
                            if #out.items>=M.MAX_RESULTS then out.truncated=true;return out end
                            out.items[#out.items+1]={book_id=id,kind=source.kind,
                                item_id=source.kind=='marks' and row.bookmarkId or row.reviewId,preview=preview(matched)}
                        end
                    end
                end
            end
        end
    end
    return out
end
return M

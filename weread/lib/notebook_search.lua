-- Search validated account-local notebook snapshots without network or writes.
local Marks=require('weread.lib.my_cloud_marks')
local Search=require('weread.lib.shelf_search')
local M={MAX_RESULTS=200}

local function preview(value,needle)
    -- Keep enough context before the match to understand it, even when the
    -- saved note is much longer than a menu row. Offsets are UTF-8 boundaries.
    local offsets={}
    for pos in value:gmatch('()[^\128-\191]') do offsets[#offsets+1]=pos end
    local count=#offsets
    offsets[count+1]=#value+1
    local first=1
    if count>80 then
        -- Only use bytewise matching for ASCII text. A combining character
        -- can change the normalized meaning of an otherwise identical byte.
        local direct=not value:find('[\128-\255]') and string.lower(value):find(needle,1,true)
        if direct then
            local lo,hi=1,count
            while lo<hi do
                local mid=math.floor((lo+hi+1)/2)
                if offsets[mid]<=direct then lo=mid else hi=mid-1 end
            end
            first=lo
        else
            -- The match may involve case folding, compatibility characters or
            -- combining marks. Locate it with the same normalizer as search.
            local lo,hi=1,count
            while lo<hi do
                local mid=math.floor((lo+hi)/2)
                if Search.contains(value:sub(1,offsets[mid+1]-1),needle) then hi=mid else lo=mid+1 end
            end
            local ending=offsets[lo+1]-1
            lo,hi=1,lo
            while lo<hi do
                local mid=math.floor((lo+hi+1)/2)
                if Search.contains(value:sub(offsets[mid],ending),needle) then lo=mid else hi=mid-1 end
            end
            if Search.contains(value:sub(offsets[lo],ending),needle) then first=lo end
        end
    end
    local start=math.max(1,first-3)
    local ending=math.min(count,start+79)
    if count>80 and not Search.contains(value:sub(offsets[start],offsets[ending+1]-1),needle) then
        -- Prefix normalization can transiently match a base character before
        -- its combining mark arrives. Fall back to a verified suffix of the
        -- full source, so a later real match is preferred over that fragment.
        local lo,hi=1,count
        while lo<hi do
            local mid=math.floor((lo+hi+1)/2)
            if Search.contains(value:sub(offsets[mid]),needle) then lo=mid else hi=mid-1 end
        end
        local candidate=math.max(1,lo-3)
        local candidate_end=math.min(count,candidate+79)
        if Search.contains(value:sub(offsets[candidate],offsets[candidate_end+1]-1),needle) then
            start,ending=candidate,candidate_end
        end
    end
    local short=value:sub(offsets[start] or 1,offsets[ending+1]-1):gsub('[%z%c]',' ')
    return (start>1 and '…' or '')..short..(ending<count and '…' or '')
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
                                item_id=source.kind=='marks' and row.bookmarkId or row.reviewId,preview=preview(matched,needle)}
                        end
                    end
                end
            end
        end
    end
    return out
end
return M

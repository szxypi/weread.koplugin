-- Book/page normalization adapted from MiuRead's bookstore_data.lua.
-- Copyright (C) 2026 MiuRead contributors. AGPL-3.0-only; see NOTICE.
local M = { PAGE_SIZE = 20, CACHE_TTL = 15 * 60 }
local Access = require('weread.lib.read_access')
local Protocol = require('weread.lib.protocol')
local ShelfTime = require('weread.lib.shelf_time')

local function number(value)
    local n = tonumber(value)
    if n and n == n and n ~= math.huge and n ~= -math.huge then return n end
end

local function text(value)
    return (type(value) == "string" or type(value) == "number") and tostring(value) or ""
end

local function reason(value)
    if type(value)~='string' or #value>8192 then return nil end
    value=value:gsub('[%c]+',' '):match('^%s*(.-)%s*$')
    if value=='' or Protocol.utf8_substr(value,#value+1)~=value then return nil end
    local result=Protocol.utf8_substr(value,100)
    return result~=value and result..'…' or result
end

local function recent_event(book)
    if book.home_recent_account~=nil then return book.home_recent_account,ShelfTime.value(book.home_recent_at) end
    return book.recent_read_account,ShelfTime.value(book.recent_read_at)
end

-- A local event belongs to one account and one exact book. The cloud value
-- remains usable when there is no trustworthy local event.
function M.recent_time(book,saved,account)
    if type(book)~='table' then return nil end
    local cloud=ShelfTime.value(book.readUpdateTime)
    local id=text(book.bookId or book.book_id)
    local local_book=id~='' and Access.cached_book(saved,id)
    local event_account,event_time
    if type(local_book)=='table' then event_account,event_time=recent_event(local_book) end
    local owned=type(local_book)=='table' and account~=nil and account~=''
        and event_account==account
        and (local_book._library_account_key==nil or local_book._library_account_key==account)
        and (local_book.book_id==nil or text(local_book.book_id)==id)
        and (local_book.bookId==nil or text(local_book.bookId)==id)
    local latest=math.max(cloud or 0,owned and (event_time or 0) or 0)
    return latest>0 and latest or nil
end

function M.book(row)
    if type(row) ~= "table" then return end
    local b = row
    for _i = 1, 4 do
        if type(b.bookInfo) == "table" then b = b.bookInfo
        elseif type(b.book) == "table" then b = b.book
        else break end
    end
    local id = text(b.bookId or b.book_id or row.bookId)
    if id == "" then return end
    return {
        bookId = id, title = text(b.title), author = text(b.author),
        cover = text(b.cover), category = text(b.category),
        reason = reason(row.reason or b.reason),
        searchIdx = number(row.searchIdx or row.idx or b.searchIdx or b.idx),
    }
end

function M.page(kind, data, cursor)
    if type(data) ~= "table" then error("Invalid bookstore response") end
    local container = data
    if kind == "similar" then container = data.booksimilar end
    if type(container) ~= "table" then error("Missing bookstore container") end
    local rows = container.books
    if kind == "search" and type(data.results) == "table" then
        rows = {}
        for _, group in ipairs(data.results) do
            if type(group) == "table" and type(group.books) == "table" then
                for _, row in ipairs(group.books) do rows[#rows + 1] = row end
            end
        end
    elseif kind == "search" and type(data.books) ~= "table" then
        error("Missing search results")
    end
    if type(rows) ~= "table" then error("Missing bookstore books") end
    cursor = number(cursor) or 0
    local books, seen, last = {}, {}, cursor
    for _, row in ipairs(rows) do
        local book = M.book(row)
        if book then
            last = math.max(last, book.searchIdx or cursor)
            if not seen[book.bookId] then
                seen[book.bookId] = true
                books[#books + 1] = book
            end
        end
    end
    local more = container.hasMore
    if more == nil then more = #rows >= M.PAGE_SIZE end
    return { books = books, next_cursor = last,
        session_id = kind == "similar" and text(container.sessionId) or nil,
        has_more = (more == true or tonumber(more) == 1) and last > cursor }
end

-- Preserve the server hierarchy, excluding audio/comic categories and invalid IDs.
-- Adapted from MiuRead's bookstore_data.lua; see this file's attribution.
function M.categories(data)
    if type(data) ~= "table" or type(data.data) ~= "table" then error("Missing bookstore categories") end
    local ranks, categories, seen, visited = {}, {}, {}, {}
    local function parse(row, depth)
        if type(row) ~= "table" or depth > 8 or visited[row] then return end
        visited[row] = true
        local id = text(row.CategoryId or row.categoryId)
        if not id:match("^[%w_%-]+$") or text(row.title) == ""
            or (row.type ~= nil and tonumber(row.type) ~= 0) then return end
        local entry = { id = id, title = text(row.title), rank = not id:match("^%d+$"), children = {} }
        for _, child in ipairs(type(row.sublist) == "table" and row.sublist or {}) do
            local result = parse(child, depth + 1)
            if result then entry.children[#entry.children + 1] = result end
        end
        return entry
    end
    local function visit(rows, depth)
        if depth > 8 or visited[rows] then return end
        visited[rows] = true
        for _, row in ipairs(rows) do
            if type(row) == "table" then
                if type(row.categories) == "table" then visit(row.categories, depth + 1)
                else
                    local entry = parse(row, 0)
                    if entry and not seen[entry.id] then
                        seen[entry.id] = true
                        local list = entry.rank and ranks or categories
                        list[#list + 1] = entry
                    end
                end
            end
        end
    end
    visit(data.data, 0)
    return { ranks = ranks, categories = categories }
end

local function recent_limit(limit)
    limit = tonumber(limit)
    return (limit == 6 or limit == 12 or limit == 24) and limit or 12
end

-- This many distinct cloud rows already qualify at or above the returned
-- time. Older local events cannot enter the visible list.
function M.recent_floor(books, limit)
    limit = recent_limit(limit)
    local oldest, count, seen = math.huge, 0, {}
    for _, book in ipairs(books or {}) do
        local id = type(book) == 'table' and text(book.bookId or book.book_id) or ''
        if id ~= '' and not seen[id] then
            seen[id] = true
            local time = ShelfTime.value(book.readUpdateTime)
            if time and time > 0 then
                oldest, count = math.min(oldest, time), count + 1
                if count == limit then return oldest end
            end
        end
    end
end

function M.recent(books, saved, account, limit)
    local candidates, seen = {}, {}
    saved=type(saved)=='table' and saved or {}
    for _, book in ipairs(books or {}) do
        local id=type(book)=='table' and text(book.bookId or book.book_id) or ''
        if id~='' and not seen[id] then
            seen[id]=true
            local recent_time=M.recent_time(book,saved,account)
            if recent_time then
                candidates[#candidates+1]={id=id,time=recent_time,book=book,on_shelf=true}
            end
        end
    end
    -- Books opened from the store may never have been added to the cloud
    -- shelf. Only the owning account's explicit local reading event can add
    -- them here; never move them into the shelf or copy internal state.
    if type(account)=='string' and account~='' then
        for key,book in pairs(saved) do
            local id=type(book)=='table' and Access.display_book_id(book.book_id or book.bookId or key)
            local event_account,time
            if type(book)=='table' then event_account,time=recent_event(book) end
            -- A legacy numeric key cannot replace a preferred string key,
            -- including one whose local event was excluded from this view.
            if id and tostring(key)==id and (type(key)=='string' or saved[id]==nil)
                and not seen[id] and time and time>0 and event_account==account
                and (book._library_account_key==nil or book._library_account_key==account)
                and (book.book_id==nil or text(book.book_id)==id) and (book.bookId==nil or text(book.bookId)==id) then
                candidates[#candidates+1]={id=id,time=time,book=book}
                seen[id]=true
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.time==b.time then return a.id<b.id end
        return a.time>b.time
    end)
    limit = recent_limit(limit)

    -- Only prepare the books the home page will show. Keep cloud shelf rows
    -- intact and expose only display fields from locally opened off-shelf books.
    local result={}
    local function field(value,maximum)
        local result_text=text(value)
        return #result_text<=maximum and not result_text:find('[%z%c]') and result_text or ''
    end
    for i=1,math.min(limit,#candidates) do
        local candidate=candidates[i]
        local book=candidate.book
        local row
        if candidate.on_shelf then
            row={}
            for key,value in pairs(book) do row[key]=value end
        else
            local title=field(book.title,2048)
            row={bookId=candidate.id,title=title:match('^%s*$') and candidate.id or title,
                author=field(book.author,2048),cover=field(book.cover,4096),category=field(book.category,2048)}
        end
        row._recent_time=candidate.time
        result[i]=row
    end
    return result
end

return M

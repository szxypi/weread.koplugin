-- Book/page normalization adapted from MiuRead's bookstore_data.lua.
-- Copyright (C) 2026 MiuRead contributors. AGPL-3.0-only; see NOTICE.
local M = { PAGE_SIZE = 20, CACHE_TTL = 15 * 60 }

local function number(value)
    local n = tonumber(value)
    if n and n == n and n ~= math.huge and n ~= -math.huge then return n end
end

local function text(value)
    return (type(value) == "string" or type(value) == "number") and tostring(value) or ""
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
        searchIdx = number(row.searchIdx or row.idx or b.searchIdx or b.idx),
    }
end

function M.page(kind, data, cursor)
    if type(data) ~= "table" then error("Invalid bookstore response") end
    local container = data
    if kind == "similar" then container = data.booksimilar end
    if type(container) ~= "table" then error("Missing bookstore container") end
    local rows = container.books
    if kind == "search" then
        if type(data.results) ~= "table" then error("Missing search results") end
        rows = {}
        for _, group in ipairs(data.results) do
            if type(group) == "table" and type(group.books) == "table" then
                for _, row in ipairs(group.books) do rows[#rows + 1] = row end
            end
        end
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

-- Sort a copy: the cloud shelf's ordering and group membership must not change.
function M.recent(books, saved, account, limit)
    local result = {}
    for _, book in ipairs(books or {}) do
        local local_book = (saved or {})[book.bookId or book.book_id] or {}
        local local_time = local_book.recent_read_account == account and account ~= nil
            and (number(local_book.recent_read_at) or 0) or 0
        local recent_time = math.max(number(book.readUpdateTime) or 0, local_time)
        if recent_time > 0 then
            local copy = {}
            for key, value in pairs(book) do copy[key] = value end
            copy._recent_time = recent_time
            result[#result + 1] = copy
        end
    end
    table.sort(result, function(a, b)
        local at, bt = a._recent_time, b._recent_time
        if at == bt then return tostring(a.bookId or a.book_id) < tostring(b.bookId or b.book_id) end
        return at > bt
    end)
    limit = tonumber(limit) or 12
    if limit ~= 6 and limit ~= 12 and limit ~= 24 then limit = 12 end
    while #result > limit do table.remove(result) end
    return result
end

return M

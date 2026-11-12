-- Native annotation response contract verified by verify_native_annotations.py.
-- Endpoint shapes reference MiuRead eink_client.lua at c1893562aa25a870b8dd076d7be062a3348f823e
-- (AGPL-3.0-only, Copyright (C) 2026 MiuRead contributors).
local M = { MAX_UNDERLINES = 4096 }
local function fail(reason) error("annotation_source/" .. reason, 0) end

function M.book_id(value)
    if type(value) ~= "number" and type(value) ~= "string" then return end
    value = tostring(value)
    return #value <= 20 and value:match("^[1-9]%d*$") and value or nil
end

function M.chapter_uid(value)
    if type(value) ~= "number" and type(value) ~= "string" then fail("invalid_chapter") end
    value = tostring(value)
    if #value > 10 or not value:match("^[1-9]%d*$") or tonumber(value) > 2147483647 then fail("invalid_chapter") end
    return value
end

function M.range(value)
    if type(value) ~= "string" then fail("invalid_range") end
    local first, last = value:match("^(%d+)%-(%d+)$")
    if not first or #first > 10 or #last > 10 or tonumber(first) >= tonumber(last)
        or tonumber(last) > 2147483647 then fail("invalid_range") end
    return value
end

local function array(value, maximum, mt)
    if type(value) ~= "table" or #value > maximum or (#value == 0 and mt and getmetatable(value) ~= mt) then return false end
    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then return false end
    end
    return true
end

function M.batch(batch, client)
    local mt = client and getmetatable(client:json_decode("[]"))
    if not array(batch, 30, mt) or #batch == 0 then fail("invalid_batch") end
    local seen = {}
    for _i, item in ipairs(batch) do
        if type(item) ~= "table" then fail("invalid_batch") end
        local marker = M.range(item.range)
        if seen[marker] then fail("invalid_batch") end
        seen[marker] = true
        local count = 0
        for key in pairs(item) do
            if key ~= "range" and key ~= "maxIdx" and key ~= "count" and key ~= "synckey" then fail("invalid_batch") end
            count = count + 1
        end
        if count ~= 4 or item.maxIdx ~= 0 or item.count ~= 30 or item.synckey ~= 0 then fail("invalid_batch") end
    end
    return seen
end

function M.project(client, kind, source, book_id, chapter_uid, batch)
    book_id, chapter_uid = M.book_id(book_id), M.chapter_uid(chapter_uid)
    if not book_id then fail("invalid_book") end
    local null = client:json_decode("null")
    local mt = getmetatable(client:json_decode("[]"))
    local function present(value) return value ~= nil and value ~= null end
    local function scope(value)
        if type(value) ~= "table" then fail("invalid_object") end
        for _i, name in ipairs({ "bookId", "book_id" }) do
            if present(value[name]) and M.book_id(value[name]) ~= book_id then fail("book_mismatch") end
        end
        for _i, name in ipairs({ "chapterUid", "chapter_uid" }) do
            if present(value[name]) and M.chapter_uid(value[name]) ~= chapter_uid then fail("chapter_mismatch") end
        end
    end
    scope(source)
    for _i, name in ipairs({ "errcode", "errCode" }) do
        if present(source[name]) and source[name] ~= 0 then fail("rejected") end
    end
    if present(source.succ) and source.succ ~= true and source.succ ~= 1 then fail("rejected") end
    local field = kind == "underlines" and "underlines" or kind == "thoughts" and "reviews"
    local rows = field and source[field]
    if not array(rows, kind == "underlines" and M.MAX_UNDERLINES or 30, mt) then fail("invalid_rows") end
    local allowed = kind == "thoughts" and M.batch(batch, client) or {}
    local seen = {}
    for _i, row in ipairs(rows) do
        scope(row)
        local marker = M.range(row.range)
        if seen[marker] or (kind == "thoughts" and not allowed[marker]) then fail("unexpected_range") end
        seen[marker] = true
        if kind == "underlines" then
            for _j, name in ipairs({ "count", "score", "type" }) do
                local value = row[name]
                if present(value) and (type(value) ~= "number" or value ~= value or value < 0 or value > 1e12) then fail("invalid_counter") end
            end
        else
            if not array(row.pageReviews, 30, mt) then fail("invalid_thoughts") end
            for _j, page in ipairs(row.pageReviews) do
                scope(page)
                local review = page.review or page
                scope(review)
                for name, maximum in pairs({ content = 65536, abstract = 16384, contextAbstract = 16384 }) do
                    if present(review[name]) and (type(review[name]) ~= "string" or #review[name] > maximum) then fail("invalid_text") end
                end
                if present(review.range) then M.range(review.range) end
            end
        end
    end
    return { [field] = rows }
end

return M

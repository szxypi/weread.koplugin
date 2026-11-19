-- Verified E-Ink latest book reviews. The service's hasMore is unreliable;
-- request one extra row and compare the already displayed prefix on reload.
local Protocol = require('weread.lib.protocol')
local Reviews = require('weread.lib.book_reviews')
local M = { PAGE_SIZE = 20, MAX_ITEMS = 200 }
local function fail(kind) error('native_reviews/' .. kind, 0) end
local function integer(v, max) return type(v) == 'number' and v >= 0 and v <= max and v % 1 == 0 end
local function text(v, max, empty)
    return type(v) == 'string' and (empty or v ~= '') and #v <= max
        and not v:find('[%z\1-\8\11\12\14-\31\127]') and Protocol.utf8_substr(v, #v) == v
end
function M.book_id(value)
    return type(value) == 'string' and #value <= 20 and value:match('^[1-9]%d*$') ~= nil
end
function M.project(client, raw, book_id, limit, previous)
    if not M.book_id(book_id) or not integer(limit, M.MAX_ITEMS) or limit < 1 then fail('query') end
    local null = client:json_decode('null')
    local array = client:json_decode('[]')
    local array_mt = getmetatable(array)
    local function present(value) return value ~= nil and value ~= null end
    if type(raw) ~= 'table' or raw == null or type(raw.reviews) ~= 'table' or raw.reviews == null
        or #raw.reviews > limit + 1 or (#raw.reviews == 0 and array_mt and getmetatable(raw.reviews) ~= array_mt) then fail('rows') end
    for key in pairs(raw.reviews) do
        if not integer(key, limit + 1) or key < 1 or key > #raw.reviews then fail('rows') end
    end
    for _, key in ipairs({'errcode', 'errCode'}) do
        if present(raw[key]) and raw[key] ~= 0 then fail('rejected') end
    end
    local items, ids, seen, last_time = array, {}, {}, nil
    for index, row in ipairs(raw.reviews) do
        local review = type(row) == 'table' and row.review
        if type(review) ~= 'table' or review == null or tostring(review.bookId) ~= book_id
            or review.type ~= 4 or (present(review.isPrivate) and review.isPrivate ~= 0)
            or not text(review.reviewId, 256) or review.reviewId:find('%s')
            or row.reviewId ~= review.reviewId or seen[review.reviewId] then fail('identity') end
        if not integer(review.createTime, 4102444800) or review.createTime == 0
            or last_time and review.createTime > last_time then fail('order') end
        last_time = review.createTime
        if present(review.book) and (type(review.book) ~= 'table'
            or present(review.book.bookId) and tostring(review.book.bookId) ~= book_id) then fail('identity') end
        local author = review.author
        if not present(author) then author = {} end
        if type(author) ~= 'table' or author == null then fail('author') end
        local name = ''
        for _, key in ipairs({'nick', 'name', 'userName', 'username'}) do
            if present(author[key]) and author[key] ~= '' then name = author[key]; break end
        end
        if not text(name, 4096, true) then fail('author') end
        for _, key in ipairs({'content', 'htmlContent'}) do
            if present(review[key]) and not text(review[key], 131072, true) then fail('content') end
        end
        if present(review.star) and (not integer(review.star, 100)) then fail('rating') end
        if present(review.isFinish) and review.isFinish ~= 0 and review.isFinish ~= 1
            and review.isFinish ~= true and review.isFinish ~= false then fail('finished') end
        seen[review.reviewId], ids[index] = true, review.reviewId
        if previous and index <= #previous and previous[index] ~= review.reviewId then fail('changed') end
        if index <= limit then
            items[#items + 1] = Reviews.normalize_item({ review = {
                reviewId = review.reviewId, author = name,
                content = present(review.content) and review.content or '',
                htmlContent = present(review.htmlContent) and review.htmlContent or '',
                star = present(review.star) and review.star or 0, createTime = review.createTime,
                isFinish = present(review.isFinish) and review.isFinish or false,
            } })
        end
    end
    if previous and #ids < #previous then fail('changed') end
    local shown_ids = {}
    for i = 1, #items do shown_ids[i] = ids[i] end
    return { items = items, ids = shown_ids, limit = limit,
        has_more = #raw.reviews > limit and limit < M.MAX_ITEMS,
        limited = #raw.reviews > limit and limit >= M.MAX_ITEMS }
end
return M

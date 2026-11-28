-- Read-only replies to an identified, same-book public review.
local Protocol = require('weread.lib.protocol')
local Reviews = require('weread.lib.book_reviews')
local Book = require('weread.lib.native_book_reviews')
local M = { PAGE_SIZE = 20, MAX_ITEMS = 200 }
local function fail(kind) error('review_replies/' .. kind, 0) end
local function integer(v, max) return type(v) == 'number' and v >= 0 and v <= max and v % 1 == 0 end
local function text(v, max, empty)
    return type(v) == 'string' and (empty or v ~= '') and #v <= max
        and not v:find('[%z\1-\8\11\12\14-\31\127]') and Protocol.utf8_substr(v, #v) == v
end
function M.review_id(value)
    return text(value, 256) and not value:find('%s')
end
function M.project(client, raw, book_id, review_id, limit, previous, review_type)
    review_type = review_type or 4
    if not Book.book_id(book_id) or not M.review_id(review_id) or not integer(limit, M.MAX_ITEMS) or limit < 1
        or review_type ~= 1 and review_type ~= 4 then fail('query') end
    local null, items = client:json_decode('null'), client:json_decode('[]')
    local array_mt = getmetatable(items)
    local function present(value) return value ~= nil and value ~= null end
    if type(raw) ~= 'table' or raw == null or raw.reviewId ~= review_id or type(raw.review) ~= 'table'
        or raw.review == null or raw.review.reviewId ~= review_id or tostring(raw.review.bookId) ~= book_id
        or raw.review.type ~= review_type or present(raw.review.isPrivate)
            and raw.review.isPrivate ~= 0 and raw.review.isPrivate ~= false then fail('review') end
    if present(raw.review.book) and (type(raw.review.book) ~= 'table' or raw.review.book == null
        or present(raw.review.book.bookId) and tostring(raw.review.book.bookId) ~= book_id) then fail('review') end
    if type(raw.comments) ~= 'table' or raw.comments == null or #raw.comments > limit + 1
        or #raw.comments == 0 and array_mt and getmetatable(raw.comments) ~= array_mt then fail('rows') end
    for _, key in ipairs({'errcode', 'errCode'}) do if present(raw[key]) and raw[key] ~= 0 then fail('rejected') end end
    for key in pairs(raw.comments) do if not integer(key, limit + 1) or key < 1 or key > #raw.comments then fail('rows') end end
    local seen, ids = {}, {}
    for index, row in ipairs(raw.comments) do
        if type(row) ~= 'table' or row == null or row.reviewId ~= review_id
            or present(row.bookId) and tostring(row.bookId) ~= book_id
            or present(row.isPrivate) and row.isPrivate ~= 0 and row.isPrivate ~= false
            or not M.review_id(row.commentId) or seen[row.commentId] then fail('identity') end
        if not integer(row.createTime, 4102444800) or row.createTime == 0 then fail('time') end
        if not text(row.content, 131072, true) then fail('content') end
        local author = row.author
        if not present(author) then author = {} end
        if type(author) ~= 'table' or author == null then fail('author') end
        local name = ''
        for _, key in ipairs({'nick', 'name', 'userName', 'username'}) do
            if present(author[key]) and author[key] ~= '' then name = author[key]; break end
        end
        if not text(name, 4096, true) then fail('author') end
        if previous and index <= #previous and previous[index] ~= row.commentId then fail('changed') end
        seen[row.commentId], ids[index] = true, row.commentId
        if index <= limit then
            items[#items + 1] = Reviews.normalize_item({reviewId = row.commentId, author = name,
                content = row.content, createTime = row.createTime})
        end
    end
    if previous and #ids < #previous then fail('changed') end
    local shown_ids = {}
    for index = 1, #items do shown_ids[index] = ids[index] end
    return {items = items, ids = shown_ids, limit = limit,
        has_more = #raw.comments > limit and limit < M.MAX_ITEMS,
        limited = #raw.comments > limit and limit >= M.MAX_ITEMS}
end
return M

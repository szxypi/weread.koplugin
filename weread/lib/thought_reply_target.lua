-- Reconnect a displayed cached thought to its exact stored source record.
-- Never infer an ID from text alone or persist a guessed association.
local Annotations = require('weread.lib.annotations')
local Book = require('weread.lib.native_book_reviews')
local Replies = require('weread.lib.native_review_replies')
local M = {}
local function fail(reason) error('thought_reply/' .. reason, 0) end
local function decimal(value)
    if type(value) == 'number' then
        if value < 1 or value > 9007199254740991 or value % 1 ~= 0 then return end
        value = string.format('%.0f', value)
    end
    return type(value) == 'string' and #value <= 20 and value:match('^[1-9]%d*$') and value or nil
end
function M.resolve(source, book_id, chapter_uid, range, shown, index)
    chapter_uid = decimal(chapter_uid)
    if not Book.book_id(book_id) or not chapter_uid or type(range) ~= 'string'
        or not range:match('^%d+%-%d+$') or #range > 21 or type(shown) ~= 'table'
        or #shown < 1 or #shown > 30 or type(index) ~= 'number' or index % 1 ~= 0
        or index < 1 or index > #shown then fail('query') end
    if type(source) ~= 'table' or tostring(source.book_id) ~= book_id or decimal(source.chapter_uid) ~= chapter_uid
        or type(source.reviews) ~= 'table' or #source.reviews > 4096 then fail('source') end
    local matched
    for _, row in ipairs(source.reviews) do
        if type(row) == 'table' and row.range == range then
            if matched then fail('duplicate_range') end
            matched = row
        end
    end
    if not matched or type(matched.pageReviews) ~= 'table' or #matched.pageReviews ~= #shown then fail('missing') end
    local rebuilt = Annotations.buildThoughtPopupItems(matched)
    if #rebuilt ~= #shown then fail('changed') end
    for i, item in ipairs(rebuilt) do
        local displayed = shown[i]
        if type(displayed) ~= 'table' or item.abstract ~= displayed.abstract or item.author ~= displayed.author
            or item.content ~= displayed.content or item.likes_count ~= displayed.likes_count then fail('changed') end
    end
    local page = matched.pageReviews[index]
    local review = type(page) == 'table' and page.review
    if type(review) ~= 'table' or not Replies.review_id(page.reviewId) or page.reviewId ~= review.reviewId
        or tostring(review.bookId) ~= book_id or decimal(review.chapterUid) ~= chapter_uid
        or review.type ~= 1 or review.isPrivate ~= nil and review.isPrivate ~= 0 and review.isPrivate ~= false then fail('identity') end
    return page.reviewId
end
return M

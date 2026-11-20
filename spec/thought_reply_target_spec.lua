package.path = './?.lua;' .. package.path
local Target = require('weread.lib.thought_reply_target')
local Annotations = require('weread.lib.annotations')
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function fixture()
    local row = {range = '10-20', pageReviews = {
        {reviewId = 'r1', likesCount = 2, review = {reviewId = 'r1', bookId = '42', chapterUid = 7,
            type = 1, author = {name = 'Reader A'}, content = 'Thought A', abstract = 'Quote'}},
        {reviewId = 'r2', likesCount = 3, review = {reviewId = 'r2', bookId = '42', chapterUid = 7,
            type = 1, author = {name = 'Reader B'}, content = 'Thought B', range = '8-22'}},
    }}
    return {book_id = '42', chapter_uid = '7', reviews = {row}}, Annotations.buildThoughtPopupItems(row)
end
local source, items = fixture()
expect(Target.resolve(source, '42', '7', '10-20', items, 1) == 'r1', 'first thought not resolved')
expect(Target.resolve(source, '42', '7', '10-20', items, 2) == 'r2', 'second thought not resolved')
source.reviews[1].pageReviews[1].review.isPrivate = false
expect(Target.resolve(source, '42', '7', '10-20', items, 1) == 'r1', 'public boolean rejected')
for _, field in ipairs({'book', 'chapter', 'range', 'duplicate', 'missing', 'author', 'content', 'quote', 'likes',
    'order', 'wrapper', 'inner', 'other_book', 'other_chapter', 'private', 'type', 'short', 'index'}) do
    local raw, shown = fixture()
    local range, index = '10-20', 1
    if field == 'book' then raw.book_id = '43'
    elseif field == 'chapter' then raw.chapter_uid = '8'
    elseif field == 'range' then range = '10-21'
    elseif field == 'duplicate' then raw.reviews[2] = raw.reviews[1]
    elseif field == 'missing' then raw.reviews = {}
    elseif field == 'author' then shown[1].author = 'Other'
    elseif field == 'content' then shown[1].content = 'Other'
    elseif field == 'quote' then shown[1].abstract = 'Other'
    elseif field == 'likes' then shown[1].likes_count = 99
    elseif field == 'order' then shown[1], shown[2] = shown[2], shown[1]
    elseif field == 'wrapper' then raw.reviews[1].pageReviews[1].reviewId = 'other'
    elseif field == 'inner' then raw.reviews[1].pageReviews[1].review.reviewId = nil
    elseif field == 'other_book' then raw.reviews[1].pageReviews[1].review.bookId = '43'
    elseif field == 'other_chapter' then raw.reviews[1].pageReviews[1].review.chapterUid = 8
    elseif field == 'private' then raw.reviews[1].pageReviews[1].review.isPrivate = 1
    elseif field == 'type' then raw.reviews[1].pageReviews[1].review.type = 4
    elseif field == 'short' then table.remove(shown)
    elseif field == 'index' then index = 3 end
    expect(not pcall(Target.resolve, raw, '42', '7', range, shown, index), 'accepted invalid ' .. field)
end
print('thought_reply_target_spec: ' .. checks .. ' checks')

package.path = './?.lua;' .. package.path
local Data = require('weread.lib.native_review_replies')
local Source = require('weread.lib.native_book_reviews_source')
local null, mt = {}, {}
local function array(v) return setmetatable(v or {}, mt) end
local client = {json_decode = function(_, s) return s == 'null' and null or array() end}
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function sample(count)
    local rows = array()
    for i = 1, count do
        rows[i] = {reviewId = 'review_1', commentId = 'comment_' .. i,
            author = {name = '合成读者', token = 'discard'}, content = '合成回复 ' .. i,
            createTime = 1700000000 - i, private_field = 'discard'}
    end
    return {reviewId = 'review_1', review = {reviewId = 'review_1', bookId = '42', type = 4},
        comments = rows, commentsCount = 100, hotComments = {{private = 'discard'}}}
end
local first = Data.project(client, sample(21), '42', 'review_1', 20)
local thought = sample(1); thought.review.type = 1
expect(#Data.project(client, thought, '42', 'review_1', 20, nil, 1).items == 1, 'thought replies rejected')
thought.review.isPrivate = false; thought.comments[1].isPrivate = false
expect(#Data.project(client, thought, '42', 'review_1', 20, nil, 1).items == 1, 'public boolean rejected')
expect(not pcall(Data.project, client, thought, '42', 'review_1', 20), 'thought accepted as book review')
expect(not pcall(Data.project, client, thought, '42', 'review_1', 20, nil, 2), 'unknown review type accepted')
expect(#first.items == 20 and first.has_more and first.items[1].author == '合成读者'
    and first.items[1].content == '合成回复 1', 'first reply page failed')
expect(not first.items[1].private_field and not first.items[1].userVid and not first.items[1].hotComments,
    'non-display data escaped projection')
local next_page = Data.project(client, sample(23), '42', 'review_1', 40, first.ids)
expect(#next_page.items == 23 and not next_page.has_more, 'remaining replies failed')
expect(#Data.project(client, sample(0), '42', 'review_1', 20).items == 0, 'empty reply list failed')
local limit = Data.project(client, sample(201), '42', 'review_1', 200)
expect(#limit.items == 200 and limit.limited and not limit.has_more, 'maximum not bounded')
for _, field in ipairs({'root', 'book', 'nested_book', 'review', 'private', 'type', 'row', 'row_book', 'row_private', 'id', 'duplicate', 'time', 'author', 'content', 'rows', 'too_many', 'err', 'changed', 'short'}) do
    local raw = sample(field == 'short' and 19 or field == 'too_many' and 22 or 21)
    if field == 'root' then raw.reviewId = 'other'
    elseif field == 'book' then raw.review.bookId = '43'
    elseif field == 'nested_book' then raw.review.book = {bookId = '43'}
    elseif field == 'review' then raw.review.reviewId = 'other'
    elseif field == 'private' then raw.review.isPrivate = 1
    elseif field == 'type' then raw.review.type = 1
    elseif field == 'row' then raw.comments[1].reviewId = 'other'
    elseif field == 'row_book' then raw.comments[1].bookId = '43'
    elseif field == 'row_private' then raw.comments[1].isPrivate = 1
    elseif field == 'id' then raw.comments[1].commentId = 'bad id'
    elseif field == 'duplicate' then raw.comments[2] = raw.comments[1]
    elseif field == 'time' then raw.comments[1].createTime = false
    elseif field == 'author' then raw.comments[1].author.name = string.rep('x', 4097)
    elseif field == 'content' then raw.comments[1].content = 'bad\255'
    elseif field == 'rows' then raw.comments = {}
    elseif field == 'err' then raw.errcode = 1
    elseif field == 'changed' then raw.comments[1].commentId = 'changed' end
    expect(not pcall(Data.project, client, raw, '42', 'review_1', 20,
        (field == 'changed' or field == 'short') and first.ids or nil), 'accepted invalid: ' .. field)
end
local scope = {vid = '123', epoch = 1}
local credentials = {vid = '123', accessToken = 'synthetic-token'}
local store = {read = function() return credentials, 1, nil, false end}
local settings = {data_dir = '/unused', get = function(_, _, fallback) return fallback end,
    get_auth_scope = function() return scope end, auth_scope_matches = function(_, v) return v == scope end}
client.settings = settings
local selected = Source.capture(settings, store)
local original_decode, request, status = client.json_decode
client.json_decode = function(self, s) if s == 'fixture' then return sample(21) end return original_decode(self, s) end
client.request = function(_, options) request = options; return 'fixture', status or 200 end
local page = Source.fetch_replies(client, '42', 'review_1', 20, nil, selected, true)
expect(#page.items == 20 and page.has_more, 'native source failed')
expect(request.url == 'https://i.weread.qq.com/review/single?reviewId=review_1&commentsCount=21&commentsDirection=0&likesCount=0&synckey=0'
    and request.method == 'GET' and not request.body and request.sensitive and request.skip_cookie
    and not request.persist_response_cookies and request.headers.accessToken == 'synthetic-token', 'unsafe request')
status = 401
local ok, reason = pcall(Source.fetch_replies, client, '42', 'review_1', 20, nil, selected, true)
expect(not ok and reason == 'native_reviews/native_expired', '401 did not trigger safe recovery')
status = 429
ok, reason = pcall(Source.fetch_replies, client, '42', 'review_1', 20, nil, selected, true)
expect(not ok and reason == 'native_reviews/unavailable', 'rate limit triggered recovery')
print('native_review_replies_spec: ' .. checks .. ' checks')

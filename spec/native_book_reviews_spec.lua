package.path = './?.lua;' .. package.path
local Data = require('weread.lib.native_book_reviews')
local Source = require('weread.lib.native_book_reviews_source')
local null, mt = {}, {}
local function array(items) return setmetatable(items or {}, mt) end
local client = { json_decode = function(_, s) return s == 'null' and null or array() end }
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function sample(count)
    local rows = array()
    for i = 1, count do
        rows[i] = { reviewId = 'r' .. i, review = { reviewId = 'r' .. i, bookId = '42', type = 4,
            content = '<p>合成书评 ' .. i .. '</p>', author = { name = '合成读者', token = 'discard' },
            book = { bookId = '42', private = 'discard' }, star = 100, createTime = 1700001000 - i } }
    end
    return { reviews = rows, hasMore = 0, totalCount = 1000 }
end
local first = Data.project(client, sample(21), '42', 20)
expect(#first.items == 20 and first.has_more and first.items[1].rating == 5, 'first page or extra row lost')
expect(first.items[1].author == '合成读者' and first.items[1].content == '合成书评 1', 'display projection failed')
expect(not first.items[1].book and not first.items[1].token and not first.items[1].userVid, 'extraneous data escaped')
local second = Data.project(client, sample(41), '42', 40, first.ids)
expect(#second.items == 40 and second.has_more and second.ids[20] == 'r20', 'larger prefix failed')
local final = Data.project(client, sample(25), '42', 40, first.ids)
expect(#final.items == 25 and not final.has_more, 'bounded final prefix failed')
local empty = Data.project(client, sample(0), '42', 20)
expect(#empty.items == 0 and not empty.has_more, 'empty array failed')
local max_page = Data.project(client, sample(201), '42', 200)
expect(#max_page.items == 200 and max_page.limited and not max_page.has_more, 'maximum prefix not bounded')
local null_nick = sample(1); null_nick.reviews[1].review.author.nick = null
expect(Data.project(client, null_nick, '42', 20).items[1].author == '合成读者', 'null nickname masked author')
expect(not pcall(Data.project, client, sample(19), '42', 40, first.ids), 'shrinking prefix accepted')
for _, field in ipairs({'foreign', 'nested_foreign', 'private', 'type', 'id', 'duplicate', 'time', 'order', 'author', 'text', 'rating', 'rows', 'too_many', 'err'}) do
    local raw = sample(21)
    if field == 'foreign' then raw.reviews[1].review.bookId = '43'
    elseif field == 'nested_foreign' then raw.reviews[1].review.book.bookId = '43'
    elseif field == 'private' then raw.reviews[1].review.isPrivate = 1
    elseif field == 'type' then raw.reviews[1].review.type = 1
    elseif field == 'id' then raw.reviews[1].reviewId = 'other'
    elseif field == 'duplicate' then raw.reviews[2] = raw.reviews[1]
    elseif field == 'time' then raw.reviews[1].review.createTime = true
    elseif field == 'order' then raw.reviews[2].review.createTime = raw.reviews[1].review.createTime + 1
    elseif field == 'author' then raw.reviews[1].review.author.name = string.rep('x', 4097)
    elseif field == 'text' then raw.reviews[1].review.content = 'bad\255'
    elseif field == 'rating' then raw.reviews[1].review.star = 101
    elseif field == 'rows' then raw.reviews = {}
    elseif field == 'too_many' then raw = sample(22)
    else raw.errcode = 1 end
    expect(not pcall(Data.project, client, raw, '42', 20), 'invalid input accepted: ' .. field)
end
local changed = sample(41); changed.reviews[2].reviewId = 'new'; changed.reviews[2].review.reviewId = 'new'
expect(not pcall(Data.project, client, changed, '42', 40, first.ids), 'changed prefix accepted')
expect(not Data.book_id('CB_42') and not Data.book_id('042') and Data.book_id('42'), 'book identity validation failed')
local scope = {vid = '123', epoch = 1}
local creds = {vid = '123', accessToken = 'synthetic-token'}
local store = {read = function() return creds, 1, nil, false end}
local settings = {data_dir = '/unused', get = function(_, _, default) return default end,
    get_auth_scope = function() return scope end, auth_scope_matches = function(_, s) return s == scope end}
client.settings = settings
local selected = Source.capture(settings, store)
local decode = client.json_decode
local request, status
client.json_decode = function(self, s) if s == 'fixture' then return sample(21) end return decode(self, s) end
client.request = function(_, value) request = value; return 'fixture', status or 200 end
local loaded = Source.fetch(client, '42', 20, nil, selected, true)
expect(#loaded.items == 20 and loaded.has_more, 'native source did not project result')
expect(request.url == 'https://i.weread.qq.com/review/list?bookId=42&listType=3&listMode=1&synckey=0&count=21&maxIdx=0&tips=1'
    and request.method == 'GET' and not request.body and request.sensitive and request.skip_cookie
    and not request.persist_response_cookies and request.headers.accessToken == 'synthetic-token', 'unsafe request')
status = 401
local ok, reason = pcall(Source.fetch, client, '42', 20, nil, selected, true)
expect(not ok and reason == 'native_reviews/native_expired', '401 did not trigger safe recovery')
status = 429
ok, reason = pcall(Source.fetch, client, '42', 20, nil, selected, true)
expect(not ok and reason == 'native_reviews/unavailable', 'rate limit triggered recovery')
print('native_book_reviews_spec: ' .. checks .. ' checks')

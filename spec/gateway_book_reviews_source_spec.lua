package.path = './?.lua;' .. package.path
local Data = require('weread.lib.gateway_book_reviews_source')
local null, mt = {}, {}
local function array(v) return setmetatable(v or {}, mt) end
local codec = {json_decode = function(_, s) return s == 'null' and null or array() end}
local checks = 0
local function expect(v, label) checks = checks + 1; assert(v, label) end
local function sample(start, count, more)
    local rows = array()
    for i = start, start + count - 1 do
        rows[#rows + 1] = {idx = i, review = {reviewId = 'r' .. i, review = {
            reviewId = 'r' .. i, book = {bookId = '42'}, author = {name = '合成读者', secret = 'discard'},
            content = '<p>合成书评 ' .. i .. '</p>', star = 100, createTime = 1700000000 - i}}}
    end
    return {reviews = rows, reviewsCnt = 50, reviewsHasMore = more and 1 or 0, synckey = 1234}
end
local first = Data.project(codec, sample(1, 20, true), '42')
local image_url='https://weread-picture-1258476243.file.myqcloud.com/fixture.png'
local with_image=sample(1,1,false);with_image.reviews[1].review.review.pictures={{url=image_url}}
local image_item=Data.project(codec,with_image,'42').items[1]
expect(image_item.attachment_state=='available' and image_item.attachment_urls==image_url,'Skill image projection failed')
expect(#first.items == 20 and first.items[1].rating == 5 and first.items[1].author == '合成读者'
    and first.max_idx == 20 and first.synckey == 1234 and first.has_more, 'first Skill page failed')
expect(not first.items[1].book and not first.items[1].secret, 'non-display data escaped projection')
local second = Data.project(codec, sample(21, 20, false), '42', first)
expect(#second.items == 40 and not second.has_more and #first.items == 20, 'Skill continuation failed')
local extended = Data.project(codec, sample(21, 40, true), '42', first)
local last = Data.project(codec, sample(61, 40, false), '42', extended)
expect(#extended.items == 60 and extended.max_idx == 60 and extended.synckey == 1234 and extended.has_more,
    '40-item Skill continuation did not advance the cursor')
expect(#last.items == 100 and last.items[61].review_id == 'r61' and last.items[100].review_id == 'r100'
    and not last.has_more and #first.items == 20, '40-item final Skill continuation was lost')
local repeated = sample(1, 20, true)
expect(not pcall(Data.project, codec, repeated, '42', first), 'cursor cycle accepted')
local empty = Data.project(codec, sample(1, 0, false), '42')
expect(#empty.items == 0 and not empty.has_more, 'empty page failed')
for _, field in ipairs({'rows', 'too_many', 'book', 'private', 'id', 'nested_id', 'author', 'content', 'rating', 'time', 'idx', 'synckey', 'more', 'err'}) do
    local raw = sample(1, field == 'too_many' and 41 or 20, true)
    local review = raw.reviews[1].review.review
    if field == 'rows' then raw.reviews = {}
    elseif field == 'book' then review.book.bookId = '43'
    elseif field == 'private' then review.isPrivate = 1
    elseif field == 'id' then review.reviewId = 'bad id'
    elseif field == 'nested_id' then review.reviewId = 'other'
    elseif field == 'author' then review.author.name = string.rep('x', 4097)
    elseif field == 'content' then review.content = 'bad\255'
    elseif field == 'rating' then review.star = 101
    elseif field == 'time' then review.createTime = -1
    elseif field == 'idx' then raw.reviews[20].idx = 0
    elseif field == 'synckey' then raw.synckey = -1
    elseif field == 'more' then raw.reviewsHasMore = 3
    elseif field == 'err' then raw.errCode = 1 end
    expect(not pcall(Data.project, codec, raw, '42'), 'invalid page accepted: ' .. field)
end
local overlap = sample(20, 2, false)
expect(#Data.project(codec, overlap, '42', first).items == 21, 'duplicate review was not removed')
local previous = {items = {}, seen_cursors = {}}
for i = 1, 195 do previous.items[i] = {review_id = 'old-' .. i} end
local bounded = Data.project(codec, sample(196, 40, false), '42', previous)
expect(#bounded.items == 200 and bounded.limited and not bounded.has_more, 'large page not bounded')
local tmp = os.tmpname()
local function disk(key)
    local file = assert(io.open(tmp, 'w')); file:write('return { api_key = ', string.format('%q', key), ', auth_epoch = 0 }'); file:close()
end
disk('synthetic-key')
local memory = {api_key = 'synthetic-key', auth_epoch = 0, account = {}, cookies = {}}
local settings = {settings_file = tmp, get = function(_, key, default) local v = memory[key]; if v == nil then return default end; return v end,
    get_auth_scope = function() return nil end}
local key_only = assert(Data.capture(settings))
expect(key_only.key_only and Data.matches(settings, key_only), 'legacy key-only configuration rejected')
disk('changed-key'); expect(not Data.matches(settings, key_only), 'disk key change ignored')
disk('synthetic-key'); memory.account = {user_vid = '123'}
expect(not Data.capture(settings), 'unverified account fell back to anonymous key')
memory.account = {}; memory.cookies = {wr_vid = '123'}
expect(not Data.capture(settings), 'unverified cookie fell back to anonymous key')
memory.cookies = {}; memory.auth_epoch = 1
expect(not Data.matches(settings, key_only), 'authentication epoch change ignored')
os.remove(tmp)
local scope = {vid = '123', epoch = 1}
local state = {key = 'synthetic-key', valid = true}
settings = {get = function(_, key, fallback) if key == 'api_key' then return state.key end return fallback end,
    get_auth_scope = function() return scope end, auth_scope_matches = function(_, candidate) return state.valid and candidate == scope end}
local store = {read = function() return nil end}
local selected = assert(Data.capture(settings, store))
codec.settings = settings
local captured
codec.get_gateway_book_reviews = function(_, book, mode, cursor, sync, key)
    captured = {book, mode, cursor, sync, key}; return sample(1, 20, true)
end
local page = Data.fetch(codec, '42', 'recommended', nil, selected)
expect(#page.items == 20 and captured[2] == 1 and captured[5] == 'synthetic-key', 'captured Skill fetch failed')
state.key = 'other-key'
expect(not pcall(Data.fetch, codec, '42', 'latest', nil, selected), 'changed Skill key accepted')
print('gateway_book_reviews_source_spec: ' .. checks .. ' checks')

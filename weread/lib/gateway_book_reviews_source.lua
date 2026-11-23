-- Owner-bound Skill book reviews; only display fields cross the worker pipe.
local Access = require('weread.lib.native_gateway_access')
local Reviews = require('weread.lib.book_reviews')
local Protocol = require('weread.lib.protocol')
local M = {MAX_ITEMS = 200}
local function fail(kind) error('gateway_reviews/' .. kind, 0) end
local function integer(value, max)
    return type(value) == 'number' and value >= 0 and value <= max and value % 1 == 0
end
local function text(value, maximum, empty)
    return type(value) == 'string' and (empty or value ~= '') and #value <= maximum
        and not value:find('[%z\1-\8\11\12\14-\31\127]') and Protocol.utf8_substr(value, #value) == value
end
-- Preserve older installations configured only with a Skill key, without
-- treating an inconsistent or partially signed-in account as anonymous.
local function key_only(settings)
    if not settings or not settings.get or type(settings.settings_file) ~= 'string' then return end
    local key, epoch = settings:get('api_key', ''), settings:get('auth_epoch', 0)
    local account, cookies = settings:get('account', {}), settings:get('cookies', {})
    if not text(key, 4096) or key:find('%s') or not integer(epoch, 9007199254740991)
        or type(account) ~= 'table' or account.user_vid ~= nil and tostring(account.user_vid) ~= ''
        or type(cookies) ~= 'table' or cookies.wr_vid ~= nil then return end
    local ok, disk = pcall(dofile, settings.settings_file)
    if not ok or type(disk) ~= 'table' or disk.api_key ~= key or (disk.auth_epoch or 0) ~= epoch
        or type(disk.account or {}) ~= 'table' or disk.account and disk.account.user_vid ~= nil and tostring(disk.account.user_vid) ~= ''
        or type(disk.cookies or {}) ~= 'table' or disk.cookies and disk.cookies.wr_vid ~= nil then return end
    return {api_key = key, key_only = true, epoch = epoch}
end
function M.capture(settings, store)
    local selected, reason = Access.capture(settings, store)
    if selected and selected.api_key then return selected end
    return key_only(settings), reason
end
function M.matches(settings, selected)
    if selected and selected.key_only then
        local current = key_only(settings)
        return current ~= nil and current.api_key == selected.api_key and current.epoch == selected.epoch
    end
    return Access.matches(settings, selected)
end
function M.project(client, raw, book_id, previous)
    local null, array = client:json_decode('null'), client:json_decode('[]')
    local mt = getmetatable(array)
    local function present(value) return value ~= nil and value ~= null end
    if type(raw) ~= 'table' or raw == null or type(raw.reviews) ~= 'table' or raw.reviews == null
        or #raw.reviews > 20 or #raw.reviews == 0 and mt and getmetatable(raw.reviews) ~= mt then fail('rows') end
    for _, key in ipairs({'errcode', 'errCode'}) do
        if present(raw[key]) and tonumber(raw[key]) ~= 0 then fail('rejected') end
    end
    if present(raw.succ) and raw.succ ~= true and raw.succ ~= 1 and raw.succ ~= '1' then fail('rejected') end
    for key in pairs(raw.reviews) do if not integer(key, 20) or key < 1 or key > #raw.reviews then fail('rows') end end
    local more = raw.reviewsHasMore
    if present(more) and more ~= true and more ~= false and more ~= 0 and more ~= 1 and more ~= '0' and more ~= '1' then fail('page') end
    local clean = {reviews = array, reviewsHasMore = more == true or more == 1 or more == '1'}
    for _, key in ipairs({'reviewsCnt', 'recentTotalCnt', 'synckey'}) do
        if present(raw[key]) then
            local value = tonumber(raw[key])
            if not integer(value, 9007199254740991) then fail('page') end
            clean[key] = value
        end
    end
    for _, row in ipairs(raw.reviews) do
        if type(row) ~= 'table' or row == null then fail('row') end
        local idx = tonumber(row.idx)
        if present(row.idx) and not integer(idx, 9007199254740991) then fail('cursor') end
        local review, wrapper_id = row, nil
        for _depth = 1, 4 do
            if present(review.reviewId) then
                if not text(review.reviewId, 256) or review.reviewId:find('%s')
                    or wrapper_id and wrapper_id ~= review.reviewId then fail('identity') end
                wrapper_id = review.reviewId
            end
            if not present(review.review) then break end
            if type(review.review) ~= 'table' then fail('row') end
            review = review.review
        end
        if present(review.bookId) and tostring(review.bookId) ~= book_id then fail('book') end
        if present(review.book) and (type(review.book) ~= 'table' or review.book == null
            or present(review.book.bookId) and tostring(review.book.bookId) ~= book_id) then fail('book') end
        local rid = present(review.reviewId) and review.reviewId or wrapper_id
        if rid ~= nil and (not text(rid, 256) or rid:find('%s') or wrapper_id and wrapper_id ~= rid) then fail('identity') end
        if present(review.isPrivate) and review.isPrivate ~= 0 and review.isPrivate ~= '0'
            and review.isPrivate ~= false then fail('private') end
        local author = present(review.author) and review.author or ''
        if type(author) == 'table' then
            local name = ''
            for _, key in ipairs({'nick', 'name', 'userName', 'username'}) do
                if present(author[key]) and author[key] ~= '' then name = author[key]; break end
            end
            author = name
        end
        if not text(author, 4096, true) then fail('author') end
        for _, key in ipairs({'content', 'htmlContent'}) do
            if present(review[key]) and not text(review[key], 131072, true) then fail('content') end
        end
        local rating = present(review.star) and tonumber(review.star) or 0
        if not integer(rating, 100) then fail('rating') end
        local created = present(review.createTime) and tonumber(review.createTime) or 0
        if not integer(created, 4102444800000) then fail('time') end
        local finished = review.isFinish
        if present(finished) and finished ~= true and finished ~= false and finished ~= 0 and finished ~= 1
            and finished ~= '0' and finished ~= '1' then fail('finished') end
        local clean_review = {
            reviewId = rid, author = author, content = present(review.content) and review.content or '',
            htmlContent = present(review.htmlContent) and review.htmlContent or '', star = rating,
            createTime = created, isFinish = finished == true or finished == 1 or finished == '1'}
        local attachment = require('weread.lib.thought_attachments').project(review,present)
        if attachment then clean_review.attachment_state, clean_review.attachment_urls = attachment.state, attachment.urls end
        clean.reviews[#clean.reviews + 1] = {idx = idx, review = clean_review}
    end
    local page = Reviews.append_page(previous, clean)
    if #page.items > M.MAX_ITEMS then
        for index = #page.items, M.MAX_ITEMS + 1, -1 do page.items[index] = nil end
        page.has_more, page.limited = false, true
    elseif page.has_more and (#page.items >= M.MAX_ITEMS or #page.seen_cursors >= 100) then
        page.has_more, page.limited = false, true
    end
    return page
end
function M.fetch(client, book_id, mode, previous, selected)
    if not selected or not selected.api_key or not M.matches(client.settings, selected) then fail('session_changed') end
    local mode_id = mode == 'recommended' and 1 or mode == 'latest' and 3
    if not mode_id then fail('mode') end
    local ok, raw = pcall(client.get_gateway_book_reviews, client, book_id, mode_id,
        previous and previous.max_idx, previous and previous.synckey, selected.api_key)
    if not M.matches(client.settings, selected) then fail('session_changed') end
    if not ok then fail('unavailable') end
    return M.project(client, raw, book_id, previous)
end
return M

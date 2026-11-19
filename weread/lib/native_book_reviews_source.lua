-- Account-bound read-only source. Raw responses stay in the worker.
local Access = require('weread.lib.native_gateway_access')
local Auth = require('weread.lib.native_authorization')
local Data = require('weread.lib.native_book_reviews')
local M = { capture = Access.capture, matches = Access.matches }
local function fail(reason) error('native_reviews/' .. reason, 0) end
function M.fetch(client, book_id, limit, previous, selected, recover_auth)
    if not selected or not selected.native then fail('access_required') end
    local function current() if not M.matches(client.settings, selected) then fail('session_changed') end end
    current()
    local auth = Auth:new(client, { expected_vid = selected.native.scope.vid,
        is_current = function() return M.matches(client.settings, selected) end })
    local ok, raw = pcall(auth.read_book_reviews, auth, selected.native.credentials, book_id, limit + 1)
    auth:cancel(); current()
    if not ok then
        if raw == 'native_auth/book_reviews/http_401' and recover_auth and not selected.native.renewal_pending then
            fail('native_expired')
        end
        fail('unavailable')
    end
    return Data.project(client, raw, book_id, limit, previous)
end

function M.fetch_replies(client, book_id, review_id, limit, previous, selected, recover_auth, review_type)
    if not selected or not selected.native then fail('access_required') end
    local function current() if not M.matches(client.settings, selected) then fail('session_changed') end end
    current()
    local auth = Auth:new(client, {expected_vid = selected.native.scope.vid,
        is_current = function() return M.matches(client.settings, selected) end})
    local ok, raw = pcall(auth.read_review_replies, auth, selected.native.credentials, review_id, limit + 1)
    auth:cancel(); current()
    if not ok then
        if raw == 'native_auth/review_replies/http_401' and recover_auth and not selected.native.renewal_pending then
            fail('native_expired')
        end
        fail('unavailable')
    end
    return require('weread.lib.native_review_replies').project(client, raw, book_id, review_id, limit, previous, review_type)
end
return M

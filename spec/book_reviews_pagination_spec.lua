package.path = './?.lua;' .. package.path
local function empty() return {} end
for _, name in ipairs({'weread.lib.book_store', 'ui/widget/confirmbox', 'weread.lib.content',
    'weread.lib.shelf_groups', 'weread.lib.shelf_flags', 'weread.lib.shelf_search', 'weread.lib.shelf_time',
    'weread.lib.volatile_shelf', 'ui/widget/inputdialog', 'ui/widget/textviewer',
    'weread.lib.protocol', 'weread.lib.read_access', 'weread.ui.book_reviews_view'}) do package.preload[name] = empty end
package.preload['weread.lib.logger'] = function() return {err = function() end} end
package.preload['weread.lib.plugin_util'] = function()
    return {tr = function(v) return v end, T = function(v) return v end, log_error = tostring, display_error = tostring}
end
package.preload['ui/uimanager'] = empty
local native_opens, gateway_opens, native_cancels, gateway_cancels = 0, 0, 0, 0
local native_cache=false
local native_selected, gateway_selected = {native = {}}, {api_key = 'synthetic'}
package.preload['weread.lib.native_book_reviews_source'] = function() return {capture = function() return native_selected end} end
package.preload['weread.lib.gateway_book_reviews_source'] = function() return {capture = function() return gateway_selected end} end
package.preload['weread.ui.native_book_reviews'] = function()
    return {cancel = function() native_cancels = native_cancels + 1 end,
        open = function(_, book, selected) assert(book.book_id == '42' and selected == native_selected); native_opens = native_opens + 1
            return selected~=nil or native_cache end}
end
package.preload['weread.ui.gateway_book_reviews'] = function()
    return {cancel = function() gateway_cancels = gateway_cancels + 1 end,
        open = function(_, book, selected) assert(book.book_id == '42' and selected == gateway_selected); gateway_opens = gateway_opens + 1; return true end}
end
local Library = require('weread.ui.library')
local configured, allowed, info, online = false, true, nil, true
local host = {settings = {is_api_configured = function() return configured end},
    requireLogin = function() return allowed end, showInfo = function(_, message) info = message end,
    isNetworkOnline = function() return online end}
for key, value in pairs(Library) do if host[key] == nil then host[key] = value end end
local book = {book_id = '42'}
assert(host:showBookReviews(book) and native_opens == 1 and gateway_opens == 0, 'native route lost')
configured = true
assert(host:showBookReviews(book) and gateway_opens == 1 and native_cancels > 0, 'Skill route lost')
configured = false; native_selected = nil; allowed = false
assert(not host:showBookReviews(book) and gateway_opens == 1, 'missing authorization opened a list')
native_cache=true
assert(host:showBookReviews(book) and gateway_opens==1,'cached reviews required native authorization')
configured=true;online=false
assert(host:showBookReviews(book) and gateway_opens==1,'offline Skill route skipped saved native reviews')
native_cache=false;online=true
configured = true; allowed = true; gateway_selected = nil
assert(not host:showBookReviews(book) and info == 'Book review authorization changed. Please sign in again.',
    'inconsistent authorization was silently used')
assert(gateway_cancels > 0, 'old Skill owner was not cancelled')
print('book_reviews_pagination_spec: owner-bound native and Skill routing passed')

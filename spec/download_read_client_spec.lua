package.path = './?.lua;' .. package.path
local Pacing = require('weread.lib.download_read_client')
local checks = 0
local function expect(ok, message)
    checks = checks + 1
    assert(ok, message)
end
local events, calls = {}, {}
local settings = { marker = 'synthetic-settings' }
local original = { settings = settings }
local headers = { marker = 'synthetic-headers' }
function original:request(options)
    expect(self == original, 'transport lost its original client')
    calls[#calls + 1] = options
    events[#events + 1] = 'read'
    if options and options.throw then error('synthetic transport failure', 0) end
    return 'synthetic body', 200, headers, 'synthetic status'
end
function original:get_text(url)
    expect(self.settings == settings, 'helper lost its settings')
    return self:request{ url = url, method = 'GET' }
end
local request = original.request
local proxy = Pacing.wrap(original, function(seconds)
    expect(seconds == 1 and events[#events] == 'read', 'wait did not follow the read')
    events[#events + 1] = 'wait'
end)
expect(proxy ~= original and original.request == request and proxy.settings == settings, 'shared client was mutated')
local value, code, returned, status = proxy:get_text('https://weread.qq.com/web/reader/abc123k456')
expect(value == 'synthetic body' and code == 200 and returned == headers and status == 'synthetic status', 'response was changed')
expect(#events == 2 and events[2] == 'wait', 'Reader GET was not paced')
for _i, shard in ipairs({ 'e_0', 'e_1', 'e_2', 'e_3', 't_0', 't_1' }) do
    local before = #events
    local options = { url = 'https://weread.qq.com/web/book/chapter/' .. shard, body = '{}' }
    proxy:request(options)
    expect(calls[#calls] == options and #events == before + 2, 'source read changed or was not paced')
end
for _i, options in ipairs({
    { url = 'https://weread.qq.com/web/book/read', body = '{}' },
    { url = 'https://weread.qq.com/web/login/renewal', body = '{}' },
    { url = 'https://weread.qq.com/web/shelf/add', body = '{}' },
    { url = 'https://weread.qq.com/web/book/chapterInfos', body = '{}' },
    { url = 'https://weread.qq.com/web/book/getProgress?bookId=900001' },
    { url = 'https://weread.qq.com/web/reader/abc123', body = '{}' },
    { url = 'https://other.invalid/web/reader/abc123' },
    { url = 'https://weread.qq.com.attacker.invalid/web/reader/abc123' },
    { url = 'http://weread.qq.com/web/reader/abc123' },
    { url = 'https://weread.qq.com/web/book/chapter/e_0', method = 'GET' },
    { url = 'https://weread.qq.com/web/book/chapter/e_0?extra=1', body = '{}' },
    { url = 'https://res.weread.qq.com/resource' },
}) do
    local before = #events
    proxy:request(options)
    expect(#events == before + 1 and events[#events] == 'read', 'unrelated request was paced')
end
local before = #events
expect(not pcall(proxy.request, proxy, { url = 'https://weread.qq.com/web/reader/abc123', throw = true }), 'transport failure was hidden')
expect(#events == before + 1, 'transport failure slept or retried')
original:get_text('https://weread.qq.com/web/reader/abc123')
expect(events[#events] == 'read' and original.request == request, 'wrapper affected direct UI requests')
local nil_proxy = Pacing.wrap({ request = function() return nil, 403, nil, 'denied' end }, function() end)
value, code, returned, status = nil_proxy:request{ url = 'https://weread.qq.com/web/reader/abc123' }
expect(value == nil and code == 403 and returned == nil and status == 'denied', 'nil values or rejection were changed')
print(('download_read_client_spec: %d checks'):format(checks))

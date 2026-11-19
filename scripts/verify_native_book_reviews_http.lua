-- Private stdin/stdout only. No screenshots, persistent settings or data files.
require('ffi').log = function() end
require('setupkoenv')
package.path = '/source/?.lua;' .. package.path
G_defaults = require('luadefaults'):open()
G_reader_settings = require('luasettings'):wrap({})
local json = require('json')
local input = json.decode(assert(io.read('*a')))
local phase, requests = 'setup', 0
local ok = pcall(function()
    local grant, book = assert(input.credentials), assert(input.book_id)
    assert(type(book) == 'string' and book:match('^[1-9]%d*$') and #book <= 20)
    local scope = {vid = grant.vid, epoch = 1}
    local store = {read = function() return grant, 1, nil, false end}
    local settings = {data_dir = '/unused', get = function(_, _, fallback) return fallback end,
        get_auth_scope = function() return scope end, auth_scope_matches = function(_, value) return value == scope end}
    phase = 'client_import'
    local Client = require('weread.lib.client')
    local client = Client:new(settings)
    local request = client.request
    client.request = function(self, options)
        local count = requests == 0 and 21 or 41
        local expected = 'https://i.weread.qq.com/review/list?bookId=' .. book
            .. '&listType=3&listMode=1&synckey=0&count=' .. count .. '&maxIdx=0&tips=1'
        assert(requests < 2 and options.url == expected and options.method == 'GET' and not options.body
            and options.sensitive and options.skip_cookie and not options.persist_response_cookies)
        requests = requests + 1
        return request(self, options)
    end
    phase = 'source_import'
    local Source = require('weread.lib.native_book_reviews_source')
    local Model = require('weread.lib.native_book_reviews')
    phase = 'source_capture'
    local selected = assert(Source.capture(settings, store))
    local function compare(actual, expected)
        assert(#actual.items == #expected.items and actual.has_more == expected.has_more)
        for index, review in ipairs(actual.items) do
            local other = expected.items[index]
            for _, field in ipairs({'review_id', 'author', 'content', 'rating', 'create_time', 'is_finish'}) do
                assert(review[field] == other[field])
            end
        end
    end
    phase = 'first_http'
    local first = Source.fetch(client, book, 20, nil, selected, false)
    phase = 'first_compare'
    local expected_first = Model.project(client, input.first, book, 20)
    compare(first, expected_first)
    phase = 'second_http'
    local second = Source.fetch(client, book, 40, first.ids, selected, false)
    phase = 'second_compare'
    local expected_second = Model.project(client, input.second, book, 40, expected_first.ids)
    compare(second, expected_second)
    phase = 'complete'
end)
io.write('\nWEREAD_NATIVE_REVIEWS_HTTP=' .. json.encode({result = ok and 'PASS' or 'UNVERIFIED', phase = phase, requests = requests}) .. '\n')

-- Detect a definite 401 only on the selected book's read-only preparation and
-- chapter requests. The ordinary client and unrelated calls are untouched.
local Protocol = require('weread.lib.protocol')
local Context = require('weread.lib.reader_context')
local Cookie = require('weread.lib.cookie')
local M = {}

function M.wrap(client, book, chapter)
    local id = Context.book_id(book)
    local reader = Context.url(book)
    local root = Protocol.reader_url(id)
    local uid = chapter and chapter.chapterUid and tostring(chapter.chapterUid)
    local chapter_reader = uid and Protocol.reader_url(id, uid)
    local proxy = setmetatable({book_reading_auth_classification=true}, {__index=client})
    function proxy:request(options)
        local method=options.method or (options.body and 'POST' or 'GET')
        local url=options.url
        local scoped=type(url)=='string' and method=='GET' and not options.body
            and (url==reader or url==root or url==chapter_reader)
        if method=='POST' and type(options.body)=='string' and #options.body<=16384 and type(url)=='string' then
            local ok,body=pcall(client.json_decode,client,options.body)
            if ok and type(body)=='table' and url=='https://weread.qq.com/web/book/chapterInfos' then
                scoped=type(body.bookIds)=='table' and #body.bookIds==1 and body.bookIds[1]==id
                for key in pairs(body) do if key~='bookIds' then scoped=false end end
                if scoped then for key in pairs(body.bookIds) do if key~=1 then scoped=false end end end
            elseif ok and uid and url:match('^https://weread%.qq%.com/web/book/chapter/[et]_[0-3]$') then
                scoped=body.b==Protocol.e(id) and body.c==Protocol.e(uid)
            end
        end
        local request=options
        if scoped then
            request={};for key,value in pairs(options) do request[key]=value end
            request.persist_response_cookies=false
        end
        local value,code,headers,status=client:request(request)
        if scoped and code==401 then error('book_reading/web_expired',0) end
        if scoped and code and code>=200 and code<300 and not options.skip_cookie
            and options.persist_response_cookies~=false and type(headers)=='table'
            and type(client.settings)=='table' and not client.settings.mock_endpoint then
            for key,cookie in pairs(headers) do
                if tostring(key):lower()=='set-cookie' and cookie~=nil then
                    local owner=client.settings:get_auth_scope()
                    local prior=client.settings:get('cookies',{})
                    local updated=Cookie.merge_set_cookie(Cookie.merge(prior,{}),cookie)
                    if not owner or tostring(updated.wr_vid or '')~=owner.vid
                        or type(updated.wr_skey)~='string' or #updated.wr_skey<8 then
                        error('book_reading/session_changed',0)
                    end
                    client.settings:merge_set_cookie(cookie);break
                end
            end
        end
        return value,code,headers,status
    end
    return proxy
end
return M

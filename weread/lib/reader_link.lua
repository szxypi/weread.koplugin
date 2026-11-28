-- Standard Reader-link metadata import. Python and real responses verified first.
local Access=require('weread.lib.read_access')
local Cookie=require('weread.lib.cookie')
local Metadata=require('weread.lib.book_metadata')
local Protocol=require('weread.lib.protocol')
local M={capture=Access.capture,matches=Access.matches}
local function fail(reason) error('reader_link/'..reason,0) end
function M.canonical(value)
    if type(value)~='string' or #value>4096 then return nil end
    value=value:gsub('^%s+',''):gsub('%s+$','')
    if value:find('[%z%c%s]') then return nil end
    local scheme,host,path=value:match('^([%a][%w+.-]*)://([^/?#]+)([^?#]*)')
    if not scheme or scheme:lower()~='https' or host:lower()~='weread.qq.com' then return nil end
    local slug,chapter=path:match('^/web/reader/([0-9a-fg]+)k([0-9a-fg]+)$')
    if not slug then slug=path:match('^/web/reader/([0-9a-fg]+)$') end
    if not slug or #slug<20 or #slug>128 or (chapter and (#chapter<20 or #chapter>128)) then return nil end
    return 'https://weread.qq.com/web/reader/'..slug
end
function M.record(value)
    if type(value)~='table' or type(value.metadata)~='table' then fail('invalid') end
    local id=Access.book_id(value.metadata.bookId)
    local url=M.canonical(value.reader_url)
    if not id or url~=Protocol.reader_url(id) then fail('mismatch') end
    return {metadata=Metadata.normalize(value.metadata,id),reader_url=url}
end
function M.project(url,html,decode)
    url=M.canonical(url)
    if not url or type(html)~='string' or #html>4*1024*1024 then fail('invalid') end
    local encoded=html:match([[window%.__INITIAL_STATE__%s*=%s*(%{.-%})%s*;%s*%(function]])
    local ok,state=pcall(decode,encoded or '')
    local source=ok and type(state)=='table' and type(state.reader)=='table' and state.reader.bookInfo
    return M.record({metadata=source,reader_url=url})
end
function M.fetch(client,url,access)
    url=M.canonical(url)
    access=access or M.capture(client.settings)
    if not url or not access or not access.web then fail('web_required') end
    local function current() if not M.matches(client.settings,access) then fail('session_changed') end end
    current()
    local chunks,bytes,exceeded={},0,false
    local ok,_,code=pcall(client.request,client,{url=url,method='GET',skip_cookie=true,persist_response_cookies=false,
        sensitive=true,diagnostic_api='reader_link',timeout={8,15},
        headers={Cookie=Cookie.to_header(access.web.cookies),Referer=url,Accept='text/html,application/xhtml+xml,*/*'},
        sink=function(chunk)
            if not chunk then return 1 end
            bytes=bytes+#chunk
            if bytes>4*1024*1024 then exceeded=true;return nil,'reader_link_limit' end
            chunks[#chunks+1]=chunk;return 1
        end})
    current()
    if not ok or exceeded or code~=200 then fail('unavailable') end
    return M.project(url,table.concat(chunks),function(text) return client:json_decode(text) end)
end
return M

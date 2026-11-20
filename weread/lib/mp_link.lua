-- Read-only E-Ink article lookup. Protocol independently checked against
-- weread-omni (MIT), public-accounts.resolveArticle, and the owner's account.
local Protocol=require('weread.lib.protocol')
local Access=require('weread.lib.native_read_access')
local WebAccess=require('weread.lib.read_access')
local Cookie=require('weread.lib.cookie')
local Auth=require('weread.lib.native_authorization')
local M={MAX_RESULT=65536}
local function fail() error('mp_link/invalid',0) end
local function decode(value)
    value=value:gsub('%+',' ')
    if value:find('%%[^%x]') or value:find('%%$') or value:find('%%[%x]$') then return nil end
    return (value:gsub('%%(%x%x)',function(hex) return string.char(tonumber(hex,16)) end))
end
function M.canonical(value)
    if type(value)~='string' or #value>4096 or value:find('[%z%c%s\\]') then return nil end
    local path,tail=value:match('^https://mp%.weixin%.qq%.com(/s/[%w_%-]+)(.*)$')
    if path and (#tail==0 or tail:sub(1,1)=='?' or tail:sub(1,1)=='#') then
        local id=path:sub(4);if #id>=8 and #id<=128 then return 'https://mp.weixin.qq.com'..path end
        return nil
    end
    local query=value:match('^https://mp%.weixin%.qq%.com/s%?([^#]*)')
    if not query then return nil end
    local allowed={__biz=true,mid=true,idx=true,sn=true,chksm=true};local fields={}
    for part in (query..'&'):gmatch('(.-)&') do
        local key,raw=part:match('^([^=]+)=(.*)$')
        if key and allowed[key] then
            if fields[key] then return nil end
            fields[key]=decode(raw);if not fields[key] then return nil end
        end
    end
    local biz,mid,idx,sn,check=fields.__biz,fields.mid,fields.idx,fields.sn,fields.chksm
    if not biz or #biz<8 or #biz>128 or biz:find('[^%w+/=_%-]') or not mid or #mid>20
        or not mid:match('^[1-9]%d*$') or not idx or #idx>2 or not idx:match('^[1-9]%d*$')
        or not sn or #sn~=32 or sn:find('[^%x]') or check and (#check<8 or #check>128 or check:find('[^%x]')) then return nil end
    local parts={}
    for _,key in ipairs({'__biz','mid','idx','sn','chksm'}) do
        if fields[key] then parts[#parts+1]=key..'='..Protocol.urlencode(fields[key]) end
    end
    return 'https://mp.weixin.qq.com/s?'..table.concat(parts,'&')
end
function M.project(source,value)
    if not source or M.canonical(source)~=source or type(value)~='table' or type(value.reviewIds)~='table'
        or #value.reviewIds~=1 then fail() end
    for key in pairs(value.reviewIds) do if key~=1 then fail() end end
    local row=value.reviewIds[1]
    if type(row)~='table' or M.canonical(row.url)~=source or type(row.reviewId)~='string'
        or #row.reviewId>512 then fail() end
    local owner,article=row.reviewId:match('^MP_WXS_([1-9]%d*)_([%w_%-]+)$')
    if not owner or #owner>20 or not article or article=='' then fail() end
    return {book_id='MP_WXS_'..owner,review_id=row.reviewId}
end
function M.capture(settings,url,store)
    local source=M.canonical(url);if not source then return nil end
    local selected=Access.capture(settings,store)
    if not selected or selected.renewal_pending then return nil end
    local web=WebAccess.capture(settings)
    return {source=source,selected=selected,web=web and web.web and web or nil}
end
function M.matches(settings,input)
    return type(input)=='table' and M.canonical(input.source)==input.source and Access.matches(settings,input.selected)
        and (not input.web or WebAccess.matches(settings,input.web))
end
function M.title(value)
    if type(value)~='string' or #value>4096 or value:find('[%z%c]')
        or Protocol.utf8_substr(value,#value+1)~=value then return nil end
    return value
end
function M.extract_title(html)
    if type(html)~='string' or #html>4*1024*1024 then return nil end
    for tag in html:gmatch('<[Mm][Ee][Tt][Aa]%s+[^>]*>') do
        local fields={}
        for key,_quote,value in tag:gmatch('([%w_:%-]+)%s*=%s*(["\'])(.-)%2') do fields[key:lower()]=value end
        if type(fields.property)=='string' and fields.property:lower()=='og:title' and fields.content then
            local ok,decoded=pcall(require('util').htmlEntitiesToUtf8,fields.content)
            local title=ok and M.title(decoded)
            if title and title~='' then return title end
        end
    end
end
local function read_title(client,input,id)
    if not input.web then return nil end
    local chunks,size,overflow={},0,false
    local ok,_,code=pcall(client.request,client,{url='https://weread.qq.com/web/mp/content?reviewId='..Protocol.urlencode(id),
        method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,diagnostic_api='mp_link_title',timeout={10,20},
        headers={Cookie=Cookie.to_header(input.web.web.cookies),Accept='text/html,application/xhtml+xml,*/*',Referer='https://weread.qq.com/'},
        sink=function(chunk)
            if chunk then size=size+#chunk;if size>4*1024*1024 then overflow=true;return nil,'response_limit' end;chunks[#chunks+1]=chunk end
            return 1
        end})
    if ok and code==200 and not overflow then return M.extract_title(table.concat(chunks)) end
end
function M.read(client,settings,input)
    local function current() return M.matches(settings,input) end
    if not current() then return {ok=false,kind='unavailable'} end
    local auth=Auth:new(client,{expected_vid=input.selected.scope.vid,is_current=current})
    local ok,value=pcall(function()
        local result=M.project(input.source,auth:_request('mp_resolve','https://i.weread.qq.com/mp/getreviewid',
            {urls={input.source}},input.selected.credentials))
        if current() then result.title=read_title(client,input,result.review_id) end
        return result
    end)
    auth:cancel()
    if ok and current() then return {ok=true,book_id=value.book_id,review_id=value.review_id,title=value.title or ''} end
    return {ok=false,kind=value=='native_auth/mp_resolve/http_401' and 'login' or 'unavailable'}
end
return M

-- Read-only, owner-bound nickname refresh. Cookies and full responses stay in
-- the worker; only the validated display name returns to the parent.
local Access=require('weread.lib.read_access')
local Cookie=require('weread.lib.cookie')
local Protocol=require('weread.lib.protocol')
local M={capture=Access.capture,matches=Access.matches}

function M.valid_name(value)
    return type(value)=='string' and #value>0 and #value<=512 and value:find('%S')~=nil
        and not value:find('[%z%c]') and Protocol.utf8_substr(value,256)==value
end

function M.project(value,owner)
    if type(value)~='table' or not Access.book_id(owner) or type(owner)~='string' then return nil end
    for _i,key in ipairs({'errcode','errCode'}) do
        if value[key]~=nil and value[key]~=0 and value[key]~='0' then return nil end
    end
    if value.vid==nil and value.userVid==nil then return nil end
    for _i,key in ipairs({'vid','userVid'}) do
        if value[key]~=nil and Access.book_id(value[key])~=owner then return nil end
    end
    if not M.valid_name(value.name) then return nil end
    return value.name
end

function M.fetch(client,selected)
    local cookies=selected and selected.web and selected.web.cookies
    local owner=cookies and cookies.wr_vid
    if not Access.book_id(owner) or type(owner)~='string' or not M.matches(client.settings,selected) then return nil end
    local chunks,size,overflow={},0,false
    local ok,_,status=pcall(client.request,client,{
        url='https://weread.qq.com/api/userInfo?userVid='..Protocol.urlencode(owner),method='GET',
        headers={Cookie=Cookie.to_header(cookies),Accept='application/json',Referer='https://weread.qq.com/'},
        skip_cookie=true,persist_response_cookies=false,sensitive=true,diagnostic_api='profile_account',timeout={10,20},
        sink=function(chunk)
            if chunk then size=size+#chunk;if size>65536 then overflow=true;return nil,'profile_account_limit' end;chunks[#chunks+1]=chunk end
            return 1
        end,
    })
    if not ok or status~=200 or overflow or not M.matches(client.settings,selected) then return nil end
    local decoded,value=pcall(client.json_decode,client,table.concat(chunks))
    return decoded and M.project(value,owner) or nil
end
return M

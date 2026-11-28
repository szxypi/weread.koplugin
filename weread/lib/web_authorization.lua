-- Fixed Web-credential maintenance protocol, validated by the Python prototype.
-- Only a parent commits credentials; network tasks exchange bounded pipe values.
local Cookie=require('weread.lib.cookie')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local M={MAX_REPLY=4*1024*1024}
local KEYS={'wr_vid','wr_skey','wr_rt','wr_fp','wr_ql','wr_pf'}
local function fail(reason) error('web_auth/'..reason,0) end
local function token(value,empty)
    return type(value)=='string' and (empty or #value>0) and #value<=4096
        and not value:find('[%z%c%s;"\\]') and not value:find('[\128-\255]')
end
local function scope(value)
    return type(value)=='table' and type(value.vid)=='string' and #value.vid<=32 and value.vid:match('^[1-9]%d*$')
        and type(value.epoch)=='number' and value.epoch>=0 and value.epoch%1==0 and value.epoch<=9007199254740990
end
function M.snapshot(values,owner)
    if not scope(owner) or type(values)~='table' or type(values.cookies)~='table' then fail('invalid') end
    local cookies={}
    for _i,key in ipairs(KEYS) do
        local value=values.cookies[key]
        if value~=nil then if not token(value,false) then fail('invalid') end;cookies[key]=value end
    end
    local ticket=values.wr_ticket==nil and '' or values.wr_ticket
    local wrpa=values.wr_wrpa==nil and '' or values.wr_wrpa
    if cookies.wr_vid~=owner.vid or not Cookie.has_login_cookie(cookies) or not token(ticket,true) or not token(wrpa,true) then fail('invalid') end
    local revision=Crypto.sha256_hex(owner.vid..'\0'..owner.epoch..'\0'..Cookie.to_header(cookies)..'\0'..ticket..'\0'..wrpa)
    return {scope={vid=owner.vid,epoch=owner.epoch},cookies=cookies,wr_ticket=ticket,wr_wrpa=wrpa,revision=revision}
end
function M.memory(settings)
    local owner=settings:get_auth_scope()
    if not settings:auth_scope_matches(owner) then fail('session_changed') end
    return M.snapshot({cookies=settings:get('cookies',{}),wr_ticket=settings:get('wr_ticket',''),wr_wrpa=settings:get('wr_wrpa','')},owner)
end
function M.primary(settings)
    local ok,data=pcall(dofile,settings.settings_file)
    if not ok or type(data)~='table' or type(data.account)~='table' then fail('session_changed') end
    local owner={vid=tostring(data.account.user_vid or ''),epoch=data.auth_epoch or 0}
    return M.snapshot(data,owner),data
end
function M.capture(settings)
    local memory=M.memory(settings);local disk=M.primary(settings)
    if memory.revision~=disk.revision then fail('session_changed') end
    return memory
end
function M.current(settings,input)
    local ok,current=pcall(M.capture,settings)
    return ok and current.revision==input.revision
end
local function header(headers,name)
    for key,value in pairs(headers or {}) do if tostring(key):lower()==name then return value end end
end
local function merge(input,headers)
    local values={cookies=Cookie.merge(input.cookies,{}),wr_ticket=input.wr_ticket,wr_wrpa=input.wr_wrpa}
    local set=header(headers,'set-cookie')
    if set~=nil then
        if type(set)~='string' and type(set)~='table' then fail('invalid_receipt') end
        local bytes,count=0,0
        for _i,value in pairs(type(set)=='table' and set or {set}) do
            if type(value)~='string' then fail('invalid_receipt') end
            bytes=bytes+#value;count=count+1;if bytes>32768 or count>32 then fail('invalid_receipt') end
        end
        values.cookies=Cookie.merge_set_cookie(values.cookies,set)
    end
    for key,name in pairs({wr_ticket='x-wr-ticket',wr_wrpa='x-wrpa-0'}) do
        local value=header(headers,name)
        if value~=nil then
            if type(value)~='string' then fail('invalid_receipt') end
            if value~='' then values[key]=value end
        end
    end
    return M.snapshot(values,input.scope)
end
function M.receipt(input,data,headers)
    if type(data)~='table' or not Protocol.is_success_response(data) then fail('unconfirmed') end
    return merge(input,headers)
end
local function request(client,input,path,body,limit)
    local chunks,bytes,overflow={},0,false
    local headers={Cookie=Cookie.to_header(input.cookies),Accept='application/json',Referer='https://weread.qq.com/'}
    if body then headers['Content-Type']='application/json;charset=UTF-8';headers.Origin='https://weread.qq.com' end
    local _,code,response_headers=client:request{url='https://weread.qq.com'..path,method=body and 'POST' or 'GET',body=body,
        headers=headers,skip_cookie=true,persist_response_cookies=false,sensitive=true,diagnostic_api='web_renewal',timeout={10,20},
        sink=function(chunk)
            if chunk then bytes=bytes+#chunk;if bytes>limit then overflow=true;return nil,'response_limit' end;chunks[#chunks+1]=chunk end
            return 1
        end}
    if overflow or code~=200 then fail('unavailable') end
    local data=client:json_decode(table.concat(chunks))
    if type(data)~='table' then fail('invalid_receipt') end
    return data,response_headers
end
function M.verify(client,candidate)
    local current=M.snapshot(candidate,candidate.scope)
    local count
    for pass=1,3 do
        local data,headers
        if pass==2 then
            data,headers=request(client,current,'/web/shelf/sync',nil,M.MAX_REPLY)
            if type(data.books)~='table' or #data.books>5000 or data.errCode~=nil and data.errCode~=0
                or data.errcode~=nil and data.errcode~=0 then fail('verification_unconfirmed') end
            local array_mt=getmetatable(client:json_decode('[]'))
            if array_mt and next(data.books)==nil and getmetatable(data.books)~=array_mt then fail('verification_unconfirmed') end
            local seen=0;for key in pairs(data.books) do
                if type(key)~='number' or key<1 or key>#data.books or key%1~=0 then fail('verification_unconfirmed') end;seen=seen+1
            end
            if seen~=#data.books then fail('verification_unconfirmed') end
            count=seen
        else
            data,headers=request(client,current,'/api/userInfo?userVid='..Protocol.urlencode(current.scope.vid),nil,65536)
            local vid=data.vid
            if vid==nil then vid=data.userVid end
            if type(vid)=='number' and vid>=1 and vid<=9007199254740990 and vid%1==0 then vid=string.format('%.0f',vid) end
            if vid~=current.scope.vid or data.errCode~=nil and data.errCode~=0 or data.errcode~=nil and data.errcode~=0 then fail('verification_unconfirmed') end
        end
        current=merge(current,headers)
        -- Keep the last same-owner Cookie rotation even if a later verification
        -- GET fails. A retry verifies this receipt, never repeats the POST.
        candidate.cookies=current.cookies;candidate.wr_ticket=current.wr_ticket
        candidate.wr_wrpa=current.wr_wrpa;candidate.revision=current.revision
    end
    return current,count
end
function M.run(client,input,candidate)
    local attempted=false
    local ok,result,count=pcall(function()
        if not candidate then
            local body=client:json_encode({rq='%2Fweb%2Fbook%2Fread',ql=false})
            attempted=true
            local data,headers=request(client,input,'/web/login/renewal',body,65536)
            candidate=M.receipt(input,data,headers)
        end
        return M.verify(client,candidate)
    end)
    return {ok=ok,attempted=attempted,candidate=ok and result or candidate,book_count=ok and count or nil,
        reason=not ok and (candidate and 'verification_unconfirmed' or attempted and 'renewal_unconfirmed' or 'not_dispatched') or nil}
end
M.keys=KEYS
return M

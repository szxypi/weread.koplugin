-- Native chapter reads are independent from Web position provenance. This
-- adapter neither writes account data nor persists packages or credentials.
local Access=require('weread.lib.native_read_access')
local Auth=require('weread.lib.native_authorization')
local Catalog=require('weread.lib.translation_generation_catalog')
local Protocol=require('weread.lib.native_position_protocol')
local Url=require('weread.lib.protocol')
local Archive=require('weread.lib.native_chapter_archive')
local M={MAX_BYTES=32*1024*1024}
local BASE='https://i.weread.qq.com'
local HEADERS={baseapi='30',appver='2.1.2.10245900',basever='2.1.2.10245900',osver='11',channelId='900',
    Accept='application/json', ['User-Agent']='WeRead/2.1.2 WRBrand/Onyx wr_eink Dalvik/2.1.0 (Linux; U; Android 11; BOOX Build/onyx)'}
local function current(settings,selected,options)
    if not selected or selected.renewal_pending or not selected.scope or not Protocol.credentials(selected.credentials)
        or selected.scope.vid~=selected.credentials.vid or not Access.matches(settings,selected)
        or type(options.is_current)~='function' then return false end
    local ok,value=pcall(options.is_current)
    return ok and value==true
end
local function header(headers,name)
    if type(headers)~='table' then return nil end
    local found
    for key,value in pairs(headers) do
        if type(key)=='string' and key:lower()==name then
            if found~=nil then return nil end
            found=value
        end
    end
    return found
end
local function chapter(model,uid)
    local found
    for _,row in ipairs(model.chapters) do
        if string.format('%.0f',row.uid)==uid then
            if found then return nil end
            found=row
        end
    end
    if not found or found.free_or_owned~=true then return nil end
    return found
end
local function url(book_id,uid,version)
    local values={
        {'bookId',book_id},{'chapters','0,'..uid},{'bookType','epub'},{'bookVersion',version},
        {'pf','wechat_wx-2001-android-100-weread'},{'pfkey','pfKey'},{'zoneId',1},{'quote',''},
        {'release',1},{'stopAutoPayWhenBNE',1},{'preload',2},{'preview',0},{'offline',1},
    }
    local parts={}
    for _,pair in ipairs(values) do parts[#parts+1]=pair[1]..'='..Url.urlencode(tostring(pair[2])) end
    return BASE..'/book/chapterdownload?'..table.concat(parts,'&')
end
function M.fetch(client,settings,selected,book_id,uid,options)
    options=options or {}
    if type(options)~='table' or type(book_id)~='string' or Protocol.id(book_id)~=book_id
        or type(uid)~='string' or Protocol.id(uid)~=uid or #uid>16 or tonumber(uid)>9007199254740991 then
        return nil,'invalid'
    end
    if not current(settings,selected,options) then return nil,'session_changed' end
    local function owns() return current(settings,selected,options) end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=owns})
    local ok,value=pcall(function()
        local info=auth:_request('chapter_info',BASE..'/book/info?bookId='..Url.urlencode(book_id),nil,selected.credentials)
        local raw=auth:_request('chapter_catalog',BASE..'/book/chapterInfos',Catalog.catalog_body(book_id),selected.credentials)
        local model=Catalog.catalog(raw,book_id,info)
        assert(chapter(model,uid),'native_chapter/not_entitled')
        assert(owns(),'native_chapter/session_changed')
        local headers={}
        for key,item in pairs(HEADERS) do headers[key]=item end
        headers.vid,headers.accessToken=selected.credentials.vid,selected.credentials.accessToken
        local chunks,size={},0
        local raw_body,code,response_headers=client:request{
            url=url(book_id,uid,model.version),method='GET',headers=headers,skip_cookie=true,
            persist_response_cookies=false,sensitive=true,diagnostic_api='native_chapter_download',timeout={5,22},
            sink=function(chunk)
                if chunk then
                    size=size+#chunk
                    if size>M.MAX_BYTES then return nil,'response_limit' end
                    chunks[#chunks+1]=chunk
                end
                return 1
            end,
        }
        assert(owns(),'native_chapter/session_changed')
        code=tonumber(code)
        if code==429 then error('native_chapter/rate_limited',0) end
        if code==401 then error('native_chapter/auth_expired',0) end
        assert(code==200 and size<=M.MAX_BYTES,'native_chapter/http')
        local data=type(raw_body)=='string' and raw_body or table.concat(chunks)
        assert(#data>0 and #data<=M.MAX_BYTES,'native_chapter/size')
        local envelope=header(response_headers,'encryptkey')
        if not envelope and #data<=8192 and data:match('^%s*{') then
            local decoded,payload=pcall(client.json_decode,client,data)
            local err=decoded and type(payload)=='table' and (payload.errcode or payload.errCode)
            if err==-2014 or err==-10102 then error('native_chapter/rate_limited',0) end
            if err==-2012 then error('native_chapter/auth_expired',0) end
            if err~=nil and err~=0 then error('native_chapter/service_rejected',0) end
        end
        assert(type(envelope)=='string' and #envelope>0 and #envelope<=1024,'native_chapter/envelope')
        local result=Archive.read(data,envelope,selected.credentials.vid,{chapter_uid=uid})
        assert(owns(),'native_chapter/session_changed')
        return {book_id=book_id,chapter_uid=uid,book_version=model.version,catalog_sha256=model.digest,
            body=result.body,is_text=result.is_text,css=result.css,assets=result.assets,
            image_signatures_recognized=result.image_signatures_recognized,unusable_resources=result.unusable_resources,
            coordinate_source_authoritative=false,source_channel='eink'}
    end)
    auth:cancel()
    if not ok then
        if not owns() then return nil,'session_changed' end
        if value=='native_chapter/rate_limited' or value=='native_auth/chapter_info/http_429'
            or value=='native_auth/chapter_catalog/http_429' then return nil,'rate_limited' end
        if value=='native_chapter/auth_expired' or value=='native_auth/chapter_info/http_401'
            or value=='native_auth/chapter_catalog/http_401' then return nil,'auth_expired' end
        if value=='native_chapter/service_rejected' or value=='native_auth/chapter_info/rejected'
            or value=='native_auth/chapter_catalog/rejected' then return nil,'service_rejected' end
        if tostring(value):find('native_chapter/not_entitled',1,true) then return nil,'not_entitled' end
        return nil,'unavailable'
    end
    return value
end
return M

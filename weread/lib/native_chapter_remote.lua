-- Fetch chapter image references without cookies or authorization headers.
-- All results remain in memory; the caller owns publication and cancellation.
local Resources=require('weread.lib.native_chapter_resources')
local Crypto=require('weread.lib.crypto')
local Position=require('weread.lib.native_position_protocol')
local M={MAX_IMAGE=8*1024*1024,MAX_TOTAL=32*1024*1024}
local ALLOWED={'qq.com','qpic.cn','qlogo.cn','weixin.qq.com','myqcloud.com','qcloud.com'}
local function current(options)
    if type(options.is_current)~='function' then return false end
    local ok,value=pcall(options.is_current)
    return ok and value==true
end
function M.allowed(reference)
    if type(reference)~='string' or #reference==0 or #reference>4096 or reference:find('[%z%c%s\\]') then return nil end
    local url=reference:sub(1,2)=='//' and 'https:'..reference or reference
    local authority=url:match('^[Hh][Tt][Tt][Pp][Ss]://([^/?#]+)')
    if not authority or url:find('#',1,true) or authority:find('@',1,true) then return nil end
    local host=authority:lower()
    if host:sub(-4)==':443' then host=host:sub(1,-5) end
    if #host==0 or #host>253 or not host:match('^[a-z0-9][a-z0-9%.%-]*[a-z0-9]$')
        or host:find('..',1,true) then return nil end
    local allowed=false
    for _,suffix in ipairs(ALLOWED) do
        if host==suffix or #host>#suffix and host:sub(-#suffix-1)=='.'..suffix then allowed=true;break end
    end
    return allowed and url or nil
end
local function mime(data)
    if data:sub(1,8)=='\137PNG\r\n\26\n' then return 'image/png' end
    if data:sub(1,3)=='\255\216\255' then return 'image/jpeg' end
    if data:sub(1,6)=='GIF87a' or data:sub(1,6)=='GIF89a' then return 'image/gif' end
    if data:sub(1,4)=='RIFF' and data:sub(9,12)=='WEBP' then return 'image/webp' end
end
local SOURCE_FIELDS={'book_id','chapter_uid','book_version','catalog_sha256','reading_catalog_sha256','source_channel',
    'coordinate_source_authoritative','is_text','body','css','unusable_resources','image_signatures_recognized'}
local PART_FIELDS={'source','data'}
local ASSET_FIELDS={'source','data','media_type','href'}
local function snapshot(source)
    local result={}
    for _,key in ipairs(SOURCE_FIELDS) do result[key]=source[key] end
    for _,list in ipairs({'body_parts','style_parts','assets'}) do
        result[list]={}
        for _,row in ipairs(source[list]) do
            local saved={}
            for _,key in ipairs(list=='assets' and ASSET_FIELDS or PART_FIELDS) do saved[key]=row[key] end
            result[list][#result[list]+1]=saved
        end
    end
    return result
end
local function same_source(source,saved)
    if type(source)~='table' then return false end
    for _,key in ipairs(SOURCE_FIELDS) do if source[key]~=saved[key] then return false end end
    for _,list in ipairs({'body_parts','style_parts','assets'}) do
        if type(source[list])~='table' or #source[list]~=#saved[list] then return false end
        local count=0
        for key in pairs(source[list]) do
            if type(key)~='number' or key%1~=0 or key<1 or key>#saved[list] then return false end
            count=count+1
        end
        if count~=#saved[list] then return false end
        for i,row in ipairs(saved[list]) do
            local actual=source[list][i]
            if type(actual)~='table' then return false end
            for _,key in ipairs(list=='assets' and ASSET_FIELDS or PART_FIELDS) do
                if actual[key]~=row[key] then return false end
            end
        end
    end
    return true
end
function M.complete(client,source,options)
    options=options or {}
    if type(options)~='table' or not current(options) then return nil,'session_changed' end
    if type(source)~='table' or type(source.book_id)~='string' or Position.id(source.book_id)~=source.book_id
        or type(source.chapter_uid)~='string' or Position.id(source.chapter_uid)~=source.chapter_uid
        or not Position.integer(source.book_version,0,2147483647)
        or type(source.catalog_sha256)~='string' or #source.catalog_sha256~=64
        or not source.catalog_sha256:match('^[0-9a-f]+$') then return nil,'invalid_source' end
    local initial,reason=Resources.prepare(source)
    if not initial then return nil,reason end
    local saved=snapshot(source)
    local function ready()
        if not current(options) then return false,'session_changed' end
        if not same_source(source,saved) then return false,'source_changed' end
        return true
    end
    local assets,total,missing,downloaded,digests={},0,0,0,{}
    local function placeholder(reference)
        if options.allow_missing_images~=true then return false end
        assets[#assets+1]={source=reference,data=require('weread.lib.native_missing_image'),media_type='image/png'}
        missing=missing+1;return true
    end
    for _,reference in ipairs(initial.remote_urls) do
        local url=M.allowed(reference)
        local allowed,why=ready();if not allowed then return nil,why end
        if not url then
            if not placeholder(reference) then return nil,'remote_unsupported' end
        else
            local chunks,size={},0
            local ok,raw,code=pcall(client.request,client,{
                url=url,method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
                diagnostic_api='native_chapter_image',timeout={5,22},
                headers={Accept='image/*',['Referer']='https://weread.qq.com/'},
                sink=function(chunk)
                    if chunk then
                        size=size+#chunk
                        if size>M.MAX_IMAGE or total+size>M.MAX_TOTAL then return nil,'response_limit' end
                        chunks[#chunks+1]=chunk
                    end
                    return 1
                end,
            })
            allowed,why=ready();if not allowed then return nil,why end
            code=tonumber(code)
            if code==429 then return nil,'rate_limited' end
            local data=ok and code==200 and size<=M.MAX_IMAGE and total+size<=M.MAX_TOTAL
                and (type(raw)=='string' and raw or table.concat(chunks)) or nil
            if not data or #data==0 or #data>M.MAX_IMAGE or total+#data>M.MAX_TOTAL then
                if not placeholder(reference) then return nil,'unavailable' end
            else
                local media_type=mime(data)
                if not media_type then
                    if not placeholder(reference) then return nil,'invalid_image' end
                else
                    total=total+#data;downloaded=downloaded+1
                    assets[#assets+1]={source=reference,data=data,media_type=media_type}
                    digests[#digests+1]=Crypto.sha256_hex(data)
                end
            end
        end
    end
    local allowed,why=ready();if not allowed then return nil,why end
    local result,err=Resources.prepare(source,assets)
    if not result then return nil,err end
    if result.remote_references~=0 then return nil,'source_changed' end
    result.downloaded_images=downloaded
    result.downloaded_digests=digests
    if options.allow_missing_images==true then result.missing_images=missing end
    return result
end
return M

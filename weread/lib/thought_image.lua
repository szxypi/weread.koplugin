-- Fetch only a verified WeRead picture URL, without account credentials.
-- SQLite retains bounded image bytes for later offline viewing.
local Attachment=require('weread.lib.thought_attachments')
local Image=require('weread.lib.thought_image_data')
local Store=require('weread.lib.thought_image_store')
local Crypto=require('weread.lib.crypto')
local M={}
function M.load(client,library,owner,book,review,url,online,current)
    if type(current)~='function' or not current() or type(online)~='boolean'
        or not library or library:accountKey()~=owner then return nil,'changed' end
    if not Attachment.allowed(url) then return nil,'invalid' end
    local key=Store.key(book,review,url);if not key then return nil,'invalid' end
    -- Skill-only installations may have no WeRead account database. Public
    -- pictures still work online there, without creating an unscoped cache.
    local store=owner and Store:new(library);local data=store and store:read(owner,key)
    if not current() or library:accountKey()~=owner then return nil,'changed' end
    if not data then
        if not online then return nil,'offline' end
        local chunks,size,exceeded={},0,false
        local ok,raw,code=pcall(client.request,client,{
            url=url,method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
            diagnostic_api='thought_image',timeout={5,22},headers={Accept='image/*',Referer='https://weread.qq.com/'},
            sink=function(chunk)
                if chunk then
                    size=size+#chunk
                    if size>Image.MAX_BYTES then exceeded=true;return nil,'response_limit' end
                    chunks[#chunks+1]=chunk
                end
                return 1
            end,
        })
        if not current() or library:accountKey()~=owner then return nil,'changed' end
        if not ok or exceeded or tonumber(code)~=200 then return nil,tonumber(code)==429 and 'rate_limited' or 'unavailable' end
        data=type(raw)=='string' and raw or table.concat(chunks)
        if not Image.dimensions(data) then return nil,'invalid_image' end
        if store and not store:write(owner,key,data) then return nil,'storage' end
    end
    if not Attachment.allowed(url) or not Image.dimensions(data) or not current() or library:accountKey()~=owner then return nil,'changed' end
    return {bytes=require('mime').b64(data),sha256=Crypto.sha256_hex(data)}
end
return M

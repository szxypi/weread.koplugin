-- Fetch only a verified WeRead picture URL, without account credentials.
-- SQLite retains bounded image bytes for later offline viewing.
local Attachment=require('weread.lib.thought_attachments')
local Image=require('weread.lib.thought_image_data')
local Store=require('weread.lib.thought_image_store')
local Crypto=require('weread.lib.crypto')
local M={}
local function acquire(client,library,owner,book,review,url,online,current,preserve_existing,precommit)
    if type(current)~='function' or not current() or (type(online)~='boolean' and type(online)~='function')
        or not library or library:accountKey()~=owner then return nil,'changed' end
    if not Attachment.allowed(url) then return nil,'invalid' end
    local key=Store.key(book,review,url);if not key then return nil,'invalid' end
    -- Skill-only installations may have no WeRead account database. Public
    -- pictures still work online there, without creating an unscoped cache.
    local store=owner and Store:new(library);local data=store and store:read(owner,key)
    local status=data and 'cached' or nil
    if not current() or library:accountKey()~=owner then return nil,'changed' end
    if not data then
        if type(online)=='function' then
            local ok,value=pcall(online)
            if not current() or library:accountKey()~=owner then return nil,'changed' end
            if not ok or type(value)~='boolean' then return nil,'unavailable' end
            online=value
        end
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
        local function write_current() return current() and (not precommit or precommit()) end
        local saved=store and store:write(owner,key,data,{preserve_existing=preserve_existing==true,
            current=preserve_existing and write_current or nil})
        if store and saved~=true and saved~='exists' then return nil,'storage' end
        status=saved=='exists' and 'cached' or 'saved'
    end
    if not Attachment.allowed(url) or not Image.dimensions(data) or not current() or library:accountKey()~=owner then return nil,'changed' end
    return data,status
end
function M.load(client,library,owner,book,review,url,online,current)
    local data,why=acquire(client,library,owner,book,review,url,online,current,false)
    if not data then return nil,why end
    return {bytes=require('mime').b64(data),sha256=Crypto.sha256_hex(data)}
end
-- Explicit offline batches preserve earlier images instead of evicting them.
function M.prefetch(client,library,owner,book,review,url,current,precommit)
    if type(owner)~='string' then return nil,'changed' end
    local data,status=acquire(client,library,owner,book,review,url,true,current,true,precommit)
    if not data then return nil,status end
    if precommit and not precommit() then return nil,'changed' end
    return status
end
return M

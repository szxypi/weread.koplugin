-- Read-only native catalog projection. Position authority remains independent.
local Catalog=require('weread.lib.translation_generation_catalog')
local Crypto=require('weread.lib.crypto')
local Url=require('weread.lib.protocol')
local M={}
local BASE='https://i.weread.qq.com'

local function integer(value,maximum)
    if type(value)=='string' and value:match('^%d+$') and (value=='0' or value:sub(1,1)~='0')
        and #value<=16 then value=tonumber(value) end
    if type(value)~='number' or value~=value or value%1~=0 or value<0 or value>maximum then return nil end
    return value
end

-- The entitlement model is shared with chapter downloads. If optional display
-- fields are malformed, preserve the entitlement result but decline to expose a
-- reading catalog rather than guessing chapter indices or labels.
function M.project(raw,book_id,info)
    local model=Catalog.catalog(raw,book_id,info,true)
    local selected
    for _,row in ipairs(raw.data) do
        local id=type(row.bookId)=='number' and string.format('%.0f',row.bookId) or row.bookId
        if id==book_id then selected=row;break end
    end
    if not selected then return model end
    local chapters,digest_parts={},{}
    for index,row in ipairs(selected.updated) do
        local item=model.chapters[index]
        if item.uid>0 then
            local title=item.title or ''
            if #title>2048 or Url.utf8_substr(title,#title)~=title then return model end
            local a=row.chapterIdx~=nil and integer(row.chapterIdx,1000000) or nil
            local b=row.chapterIndex~=nil and integer(row.chapterIndex,1000000) or nil
            if row.chapterIdx~=nil and not a or row.chapterIndex~=nil and not b or a and b and a~=b then return model end
            local level=1
            if row.level~=nil then
                level=integer(row.level,100)
                if not level then return model end
            end
            local words=item.wordCount or 0
            if words>100000000 then return model end
            chapters[#chapters+1]={chapterUid=string.format('%.0f',item.uid),title=title,
                chapterIdx=a or b,level=level,wordCount=words,wordCountKnown=item.wordCount~=nil,
                downloadable=item.free_or_owned==true}
            digest_parts[#digest_parts+1]=string.format('%.0f:%s:%.0f;',item.uid,
                a~=nil and tostring(a) or b~=nil and tostring(b) or '-',level)
        end
    end
    if #chapters>0 then
        model.reading_chapters=chapters
        model.reading_digest=Crypto.sha256_hex('native-reading-catalog-v1\0'..model.digest..'\0'..table.concat(digest_parts))
    end
    return model
end

function M.read(auth,credentials,book_id,stage)
    if stage~='chapter' and stage~='native_catalog' then error('native_catalog/stage',0) end
    local body=Catalog.catalog_body(book_id)
    local info=auth:_request(stage..'_info',BASE..'/book/info?bookId='..Url.urlencode(book_id),nil,credentials)
    local raw=auth:_request(stage..'_catalog',BASE..'/book/chapterInfos',body,credentials)
    return M.project(raw,book_id,info)
end

return M

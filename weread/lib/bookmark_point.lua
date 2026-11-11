-- Exact source-bound point bookmarks. The type-0 native endpoint and CRLF
-- preview were independently verified before this Lua implementation.
local Coordinates=require('weread.lib.source_coordinates')
local Quote=require('weread.lib.selection_quote')
local Raw=require('weread.lib.annotation_source')
local Dom=require('weread.lib.source_dom')
local Marks=require('weread.lib.my_cloud_marks')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local M={}
local function fail(reason) error('bookmark_point/'..reason,0) end
function M.point(value)
    if type(value)~='string' or #value>10 or not value:match('^%d+$') then return nil end
    local at=tonumber(value)
    return at<=2147483647 and tostring(at)==value and at or nil
end
function M.can_locate(row)
    return type(row)=='table' and row.type==0 and type(row.chapterUid)=='number'
        and row.chapterUid>=1 and row.chapterUid<=2147483647 and row.chapterUid%1==0 and M.point(row.range)~=nil
end
local function trim(text)
    local first,last
    for at,char in text:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
        if Dom.normalize(char)~='' then first=first or at;last=at+#char-1 end
    end
    return first and text:sub(first,last) or ''
end
local function scan(raw,map,wanted_raw,wanted_flat)
    local flat,found,point,byte=1,0,nil,nil
    local chunks,pieces,preview={}, {}, {};local count=0
    for _i,span in ipairs(Raw.index(raw,{body_only=true})) do
        local at,offset=1,span[1]
        while at<=#span[3] do
            local token=span[3]:match('^[%z\1-\127\194-\244][\128-\191]*',at);local decoded=token
            if token=='&' then
                token=span[3]:match('^&[^%s<&]+;',at);if not token then fail('entity') end
                decoded=require('util').htmlEntitiesToUtf8(token)
            end
            if not token then fail('source') end
            local clean=assert(Dom.normalize(decoded));local runes=0
            for _char in token:gmatch('[%z\1-\127\194-\244][\128-\191]*') do runes=runes+1 end
            if clean~='' then
                if wanted_raw==offset or wanted_flat==flat then
                    local n=0;for _char in clean:gmatch('[%z\1-\127\194-\244][\128-\191]*') do n=n+1 end
                    if n~=1 then fail('entity') end
                    found,point,byte=found+1,offset,flat
                end
                pieces[#pieces+1]=clean
                if #pieces>=256 then chunks[#chunks+1]=table.concat(pieces);pieces={} end
            end
            if point~=nil and count<140 then
                for char in decoded:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
                    if count>=140 then break end;preview[#preview+1]=char;count=count+1
                end
            end
            at,offset,flat=at+#token,offset+runes,flat+#clean
        end
    end
    chunks[#chunks+1]=table.concat(pieces)
    if table.concat(chunks)~=map.flat or found~=1 or not byte then fail('point') end
    local co=map:_point(byte)
    if Quote.boundary(map,co)~=byte then fail('boundary') end
    local text=trim(table.concat(preview))
    if text=='' or #text>4096 or text:find('[%z\1-\8\11\12\14-\31\127]') then fail('preview') end
    return {range=tostring(point),markText=text,chapter_offset=co,raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw},byte
end
local function guarded(task)
    local ok,value=pcall(task)
    if ok then return value end
    return nil,type(value)=='string' and value:match('^bookmark_point/[a-z_]+$') and value or 'bookmark_point/unavailable'
end
function M.project(raw,co)
    return guarded(function()
        local map=Coordinates.build(raw,{allow_multiple_bodies=true});if not map then fail('source') end
        local byte=Quote.boundary(map,co);if not byte or byte>#map.flat then fail('boundary') end
        return scan(raw,map,nil,byte)
    end)
end
function M.from_mark(raw,book,chapter,row)
    return guarded(function()
        if not Marks.id(book) or not Marks.id(chapter) or not M.can_locate(row) or tostring(row.chapterUid)~=chapter
            or row.bookId~=nil and tostring(row.bookId)~=book or row.book_id~=nil and tostring(row.book_id)~=book then fail('scope') end
        local map=Coordinates.build(raw,{allow_multiple_bodies=true});if not map then fail('source') end
        local value,byte=scan(raw,map,M.point(row.range))
        if value.range~=row.range then fail('point') end
        if row.markText~=nil and row.markText~='' then
            if type(row.markText)~='string' or #row.markText>131072 or Protocol.utf8_substr(row.markText,#row.markText)~=row.markText then fail('preview') end
            local text=Dom.normalize(row.markText)
            if not text or text=='' or map.flat:sub(byte,byte+#text-1)~=text then fail('preview') end
        end
        if not (map:anchor(value.chapter_offset,{segment_only=true}) or map:anchor(value.chapter_offset)) then fail('anchor') end
        return {book_id=book,chapter_uid=chapter,chapter_offset=value.chapter_offset,raw_sha256=value.raw_sha256,
            raw_bytes=value.raw_bytes,basis='filtered_xhtml_utf16',upload_verified=false}
    end)
end
return M

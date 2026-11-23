-- Worker-only search of verified, account-bound native chapter EPUBs. The
-- generated XHTML has no Web position authority: anchors are local-only.
local Cache=require('weread.lib.native_direct_cache')
local Archive=require('weread.lib.source_archive')
local Coordinates=require('weread.lib.source_coordinates')
local Dom=require('weread.lib.source_dom')
local Protocol=require('weread.lib.protocol')
local NativeProtocol=require('weread.lib.native_position_protocol')
local Unicode=require('weread.lib.unicode_search')
local M={MAX_HITS=30,MAX_EXAMINED=100}
local RENDER='OEBPS/text/chapter.xhtml'

local function fold_ascii(value)
    return (value:gsub('[A-Z]',function(char) return string.char(char:byte()+32) end))
end
local function live(current)
    local ok,value=pcall(current)
    return ok and value==true
end

-- `from` is an original normalized UTF-8 byte offset, never a folded offset.
-- The caller must pin account, reader, and document through `current`.
function M.scan(settings,account,entry,keyword,from,ignore_case,current,dependencies)
    if type(current)~='function' or type(account)~='string' or NativeProtocol.id(account)~=account
        or type(entry)~='table' or type(entry.book_id)~='string'
        or not Cache.valid_entry(entry,entry.book_id,account)
        or type(keyword)~='string' or #keyword<1 or #keyword>160
        or type(from)~='number' or from~=from or from%1~=0 or from<1 or from>Coordinates.MAX_BYTES*4+1
        or ignore_case~=nil and type(ignore_case)~='boolean' or not live(current) then return {error='invalid'} end
    local cache=dependencies and dependencies.cache or Cache
    local archive=dependencies and dependencies.archive or Archive
    local ok,result=pcall(function()
        local wanted=Dom.normalize(keyword)
        if type(wanted)~='string' or wanted=='' then return {error='invalid'} end
        local saved=cache.open(settings,account,entry.book_id,entry,current)
        if not saved or type(saved.file_id)~='string' or #saved.file_id~=64
            or not saved.file_id:match('^[a-f0-9]+$') or not live(current) then return {error='unavailable'} end
        local function finish(value)
            if not live(current) then return {error='cancelled'} end
            local fresh=cache.open(settings,account,entry.book_id,entry,current)
            if not fresh or fresh.path~=saved.path or fresh.file_id~=saved.file_id or not live(current) then
                return {error='unavailable'}
            end
            return value
        end
        local members=archive.read(saved.path,{[RENDER]=Coordinates.MAX_BYTES})
        local raw=members and members[RENDER]
        local map=raw and Coordinates.build(raw,{format='web_xhtml'})
        if not map then return {error='unavailable'} end
        map:_index()
        if not live(current) then return {error='cancelled'} end
        local haystack,needle,at,resume=map.flat,wanted,from,from
        local unicode
        if ignore_case then
            if Unicode.available() and (haystack:find('[\128-\255]') or needle:find('[\128-\255]')) then
                local why
                unicode,why=Unicode.build(haystack,from,needle)
                if not unicode then return {error=why or 'unavailable'} end
                haystack,needle,at=unicode.text,unicode.needle,1
            else haystack,needle=fold_ascii(haystack),fold_ascii(needle) end
        end
        local hits,examined,unresolved={},0,0
        while #hits<M.MAX_HITS and examined<M.MAX_EXAMINED do
            if not live(current) then return {error='cancelled'} end
            local first=haystack:find(needle,at,true)
            if not first then return finish({hits=hits,complete=true,unresolved=unresolved}) end
            examined=examined+1
            local source_first,exact=first,true
            if unicode then
                local size,starts
                source_first,size,starts=unicode.locate(first)
                local ending,_,_,ending_byte=unicode.locate(first+#needle-1)
                exact=source_first~=nil and size>0 and ending~=nil and starts and ending_byte==first+#needle-1
                resume=source_first and source_first+1 or resume
            else resume=first+1 end
            at=first+1
            if exact then
                local found,co=pcall(map._point,map,source_first)
                local anchor=found and (map:anchor(co,{segment_only=true}) or map:anchor(co))
                if anchor then
                    hits[#hits+1]={anchor=anchor,chapter_uid=entry.chapter_uid,file_id=saved.file_id,byte=source_first,
                        context=map:snippet(source_first,80) or Protocol.utf8_substr(map.flat:sub(source_first),80)}
                else unresolved=unresolved+1 end
            else unresolved=unresolved+1 end
        end
        if not live(current) then return {error='cancelled'} end
        return finish({hits=hits,next_byte=resume,unresolved=unresolved})
    end)
    return ok and result or {error='unavailable'}
end
return M

-- Disambiguate old chapter mappings that point to the same EPUB.
local Context=require('weread.lib.reader_context')
local Identity=require('weread.lib.book_file_identity')
local Protocol=require('weread.lib.protocol')
local M={}
local counts_key={}

function M.shared(book,path,cache)
    if type(book)~='table' or type(path)~='string' then return false end
    local counts=cache and cache[counts_key]
    if not counts then
        counts={}
        for key,value in pairs(type(book.cached_chapters)=='table' and book.cached_chapters or {}) do
            if type(value)=='string' then
                local ok,id=pcall(Context.identifier,key,true)
                if not ok then id='invalid:'..tostring(key) end
                if counts[value]==nil then counts[value]=id
                elseif counts[value]~=id then counts[value]=true end
            end
        end
        if cache then cache[counts_key]=counts end
    end
    local reference=counts[path]
    return reference==true or reference~=nil and book.cached_full_book==path
end

local function inspect(book,path)
    local ok,result=pcall(function()
        local id=Context.book_id(book)
        local Archive=require('weread.lib.source_archive')
        local members=Archive.read(path,{['OEBPS/content.opf']=8*1024*1024,[Identity.PATH]=Identity.MAX_BYTES})
        local identity=members and Identity.decode(members[Identity.PATH])
        if members and not identity then return {kind='unknown'} end
        if not members then members=Archive.read(path,{['OEBPS/content.opf']=8*1024*1024}) end
        local opf=members and members['OEBPS/content.opf']
        if type(opf)~='string' or identity and identity.book_id~=id then return {kind='unknown'} end
        local source,count=opf:match('<dc:source>([^<]+)</dc:source>'),0
        for _ in opf:gmatch('<dc:source>') do count=count+1 end
        local spine=opf:match('<spine[^>]*>(.-)</spine>')
        if count~=1 or not source or not spine then return {kind='unknown'} end
        local items,n={},0
        for ref in spine:gmatch('<itemref%s+idref="([^"]+)"%s*/>') do
            if items[ref] then return {kind='unknown'} end
            if ref~='cover' then n=n+1 end
            if n>20000 then return {kind='unknown'} end;items[ref]=true
        end
        if n==0 or identity and identity.chapter_count~=n then return {kind='unknown'} end
        if source==Protocol.reader_url(id) and not items.chapter then
            for ref in pairs(items) do
                if ref~='cover' and not ref:match('^chapter_[%w_-]+$') then return {kind='unknown'} end
            end
            return {kind='combined',items=items}
        end
        if n~=1 or not items.chapter then return {kind='unknown'} end
        local matching
        for key,value in pairs(book.cached_chapters or {}) do
            if value==path then
                local valid,uid=pcall(Context.identifier,key,true)
                if not valid then return {kind='unknown'} end
                if source==Protocol.reader_url(id,uid) then
                    if matching and matching~=uid then return {kind='unknown'} end
                    matching=uid
                end
            end
        end
        if matching then return {kind='single',uid=matching} end
        return {kind='unknown'}
    end)
    return ok and result or {kind='unknown'}
end

function M.inspect(book,path,cache)
    if not M.shared(book,path,cache) then return {kind='unshared'} end
    if cache and cache[path] then return cache[path] end
    local result=inspect(book,path)
    if cache then cache[path]=result end
    return result
end

function M.usable(book,path,uid,cache)
    local info=M.inspect(book,path,cache)
    if info.kind=='unshared' then return true end
    local ok,id=pcall(Context.identifier,uid,true)
    if not ok then return false end
    return info.kind=='single' and info.uid==id or info.kind=='combined' and info.items['chapter_'..id]==true
end
return M

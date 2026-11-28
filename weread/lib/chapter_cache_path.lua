-- Keep single-chapter EPUBs separate even when titles or paths collide.
local Crypto=require('weread.lib.crypto')
local Context=require('weread.lib.reader_context')
local Identity=require('weread.lib.book_file_identity')
local Protocol=require('weread.lib.protocol')
local Access=require('weread.lib.read_access')
local M={}
local function filesystem()
    local ok,lfs=pcall(require,'libs/libkoreader-lfs')
    if ok then return lfs end
    return require('lfs')
end
local function stat(path)
    local fs=filesystem()
    return (fs.symlinkattributes or fs.attributes)(path)
end
local function same(a,b)
    if not a or not b then return a==b end
    return a.mode==b.mode and a.dev==b.dev and a.ino==b.ino and a.size==b.size and a.modification==b.modification
end
local function inside(path,dir)
    if type(path)~='string' or path:sub(1,#dir+1)~=dir..'/' then return false end
    local name=path:sub(#dir+2)
    return name~='' and name~='.' and name~='..' and not name:find('[/%z%c]')
end
local function exclusive(book,uid,path)
    if path==book.cached_full_book then return false end
    for key,value in pairs(book.cached_chapters or {}) do
        if value==path and tostring(key)~=uid then return false end
    end
    return true
end
local function owned(path,book_id,uid)
    local info=stat(path)
    if not info or info.mode~='file' then return false end
    local ok,result=pcall(function()
        local members=require('weread.lib.source_archive').read(path,{[Identity.PATH]=Identity.MAX_BYTES,
            ['OEBPS/content.opf']=1024*1024})
        local identity=members and Identity.decode(members[Identity.PATH])
        local opf=members and members['OEBPS/content.opf']
        if not identity or identity.book_id~=book_id or identity.chapter_count~=1 or type(opf)~='string' then return false end
        local source='<dc:source>'..Protocol.reader_url(book_id,uid)..'</dc:source>'
        local _,count=opf:gsub('<dc:source>','')
        return count==1 and opf:find(source,1,true)~=nil
    end)
    return ok and result==true
end
function M.plan(book,chapter,dir,stage_copy)
    local id=Context.book_id(book)
    if type(chapter)~='table' then error('chapter_cache/identity',0) end
    local a=chapter.chapterUid~=nil and Context.identifier(chapter.chapterUid,true)
    local b=chapter.chapterId~=nil and Context.identifier(chapter.chapterId,true)
    if not (a or b) or a and b and a~=b then error('chapter_cache/identity',0) end
    local uid=a or b
    local base=dir..'/wr-chapter-'..Crypto.sha256_hex(id..'\0'..uid)
    if stage_copy then
        local random=assert(io.open('/dev/urandom','rb'))
        local bytes=random:read(16)
        assert(random:close() and bytes and #bytes==16,'chapter_cache/nonce')
        local nonce=Crypto.sha256_hex(bytes)
        local target=base..'-'..nonce:sub(1,32)..'.epub'
        local path=target..'.pending'
        if stat(path) or stat(target) then error('chapter_cache/conflict',0) end
        return {path=path,target=target,nonce=nonce,book=id,uid=uid}
    end
    local old=Access.cached_chapter(book.cached_chapters,uid)
    local function plan(path)
        local state=stat(path)
        if not state then return {path=path,book=id,uid=uid} end
        if state.mode=='file' and exclusive(book,uid,path) and owned(path,id,uid) then
            return {path=path,book=id,uid=uid,prior=state}
        end
    end
    if inside(old,dir) then
        local value=plan(old)
        -- A missing legacy file is not evidence of ownership: use a fresh name.
        if value and value.prior then return value end
    end
    for index=0,999 do
        local path=base..(index==0 and '' or '-'..index)..'.epub'
        if exclusive(book,uid,path) then
            local value=plan(path)
            if value then return value end
        end
    end
    error('chapter_cache/capacity',0)
end
function M.current(plan)
    local now=stat(plan.path)
    if not same(plan.prior,now) then return false end
    return not now or owned(plan.path,plan.book,plan.uid)
end
function M.ready_copy(plan)
    local info=stat(plan.path)
    if not info or info.mode~='file' then error('chapter_cache/conflict',0) end
    return {path=plan.path,target=plan.target,info=info}
end

function M.publish_copy(copy)
    if not same(copy.info,stat(copy.path)) or stat(copy.target) or not os.rename(copy.path,copy.target) then return false end
    copy.path=copy.target
    return true
end

function M.discard_copy(copy)
    if same(copy.info,stat(copy.path)) then os.remove(copy.path) end
end
return M

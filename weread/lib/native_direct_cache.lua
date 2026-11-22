-- Isolated E-Ink-only EPUBs. A cached file is reused only with its own complete
-- receipt; corrupt or interrupted copies are left intact and never overwritten.
local Crypto=require('weread.lib.crypto')
local Identity=require('weread.lib.book_file_identity')
local Protocol=require('weread.lib.protocol')
local NativeProtocol=require('weread.lib.native_position_protocol')
local Path=require('weread.lib.native_direct_path')
local M={MAX_FILE=128*1024*1024,MAX_COPIES=100}
local CHUNK=65536

local function fs()
    local ok,lfs=pcall(require,'libs/libkoreader-lfs')
    if not ok then ok,lfs=pcall(require,'lfs') end
    return ok and lfs or nil
end
local function mode(lfs,path)
    return lfs.symlinkattributes and lfs.symlinkattributes(path) or lfs.attributes(path)
end
local function directory(lfs,parent,name)
    local path=parent..'/'..name
    local attr=mode(lfs,path)
    if not attr then lfs.mkdir(path);attr=mode(lfs,path) end
    if not attr or attr.mode~='directory' then return nil end
    return path
end
local function digest_file(lfs,path)
    local attr=mode(lfs,path)
    if not attr or attr.mode~='file' or attr.size<1 or attr.size>M.MAX_FILE then return nil end
    local file=io.open(path,'rb');if not file then return nil end
    local size,chain=0,Crypto.sha256_hex('native-direct-file-v1')
    while true do
        local bytes,err=file:read(CHUNK)
        if err then file:close();return nil end
        if not bytes then break end
        size=size+#bytes
        if size>M.MAX_FILE then file:close();return nil end
        chain=Crypto.sha256_hex(chain..Crypto.sha256_hex(bytes))
    end
    if not file:close() or size~=attr.size then return nil end
    return size,Crypto.sha256_hex(chain..':'..tostring(size))
end
local function archive_identity(path,book_id,uid,version,text_digest)
    local ok,result=pcall(function()
        local members=require('weread.lib.source_archive').read(path,{
            [Identity.PATH]=Identity.MAX_BYTES,['OEBPS/content.opf']=1024*1024})
        local identity=members and Identity.decode(members[Identity.PATH])
        local opf=members and members['OEBPS/content.opf']
        return identity and identity.book_id==book_id and identity.book_version==Identity.version(version)
            and identity.chapter_count==1 and type(opf)=='string'
            and members[Identity.PATH]:match('\ntext_digest=([a-f0-9]+)\n')==text_digest
            and opf:find('<dc:source>'..Protocol.reader_url(book_id,uid)..'</dc:source>',1,true)~=nil
    end)
    return ok and result==true
end
local function archive_content(path,book,chapter,prepared)
    local rendered=require('weread.lib.content').single_chapter_xhtml(book,chapter,prepared.xhtml)
    if #rendered>8*1024*1024 then return false end
    local wanted={
        ['mimetype']={maximum=128,bytes='application/epub+zip'},
        ['OEBPS/text/chapter.xhtml']={maximum=8*1024*1024,bytes=rendered},
        ['OEBPS/style.css']={maximum=8*1024*1024,bytes=prepared.css},
    }
    for _,asset in ipairs(prepared.assets) do
        if #asset.data>8*1024*1024 then return false end
        wanted['OEBPS/'..asset.href]={maximum=8*1024*1024,bytes=asset.data}
    end
    return require('weread.lib.source_archive').verify_members(path,wanted)
end
local function verified(lfs,dir,path,book,chapter,prepared,key,text_digest)
    local proof=dir..'/receipt.txt'
    local attr=mode(lfs,proof)
    if not attr or attr.mode~='file' or attr.size>256 then return false end
    local file=io.open(proof,'rb');if not file then return false end
    local text,err=file:read(257);local closed=file:close()
    if err or not closed or not text then return false end
    local saved_key,size,digest=text:match('^native%-direct%-v1\ncontent=([a-f0-9]+)\nsize=(%d+)\ndigest=([a-f0-9]+)\n$')
    if saved_key~=key or not size or #digest~=64 then return false end
    local actual,hash=digest_file(lfs,path)
    return actual~=nil and tostring(actual)==size and hash==digest
        and archive_identity(path,book.book_id,chapter.chapterUid,prepared.book_version,text_digest)
        and archive_content(path,book,chapter,prepared)
end
local function publish_receipt(dir,key,size,digest)
    local temp=dir..'/receipt.txt.part'
    local file=io.open(temp,'wb');if not file then return false end
    local ok=file:write('native-direct-v1\ncontent='..key..'\nsize='..tostring(size)..'\ndigest='..digest..'\n')
    local closed=file:close()
    if not ok or not closed then os.remove(temp);return false end
    if not os.rename(temp,dir..'/receipt.txt') then os.remove(temp);return false end
    return true
end
local function safe_text(value)
    return type(value)=='string' and #value<=2048 and not value:find('[%z%c]')
        and Protocol.utf8_substr(value,#value)==value
end
local function hash(value)
    return type(value)=='string' and #value==64 and value:match('^[a-f0-9]+$')~=nil
end
local function content_key(account,book,chapter,prepared)
    local parts={'native-direct-content-v1',account,prepared.book_id,prepared.chapter_uid,
        tostring(prepared.book_version),prepared.catalog_sha256,prepared.reading_catalog_sha256,
        prepared.source_sha256,Crypto.sha256_hex(prepared.xhtml),Crypto.sha256_hex(prepared.css),
        book.title,book.author,chapter.title,tostring(prepared.missing_images)}
    local seen,count,total={},0,0
    if #prepared.assets>2048 then return nil end
    for index in pairs(prepared.assets) do
        if type(index)~='number' or index%1~=0 or index<1 or index>#prepared.assets then return nil end
        count=count+1
    end
    if count~=#prepared.assets then return nil end
    for _,asset in ipairs(prepared.assets) do
        if type(asset)~='table' or type(asset.href)~='string'
            or seen[asset.href] or type(asset.data)~='string' or #asset.data==0
            or type(asset.media_type)~='string' then return nil end
        local digest,extension=asset.href:match('^images/eink%-([a-f0-9]+)%.([a-z]+)$')
        local allowed={['image/png']='png',['image/jpeg']='jpg',['image/gif']='gif',['image/webp']='webp'}
        if not digest or #digest~=64 or digest~=Crypto.sha256_hex(asset.data) or allowed[asset.media_type]~=extension then return nil end
        total=total+#asset.data;if total>64*1024*1024 then return nil end
        seen[asset.href]=true
        parts[#parts+1]=asset.href;parts[#parts+1]=asset.media_type;parts[#parts+1]=digest
    end
    return Crypto.sha256_hex(table.concat(parts,'\0'))
end

function M.publish(settings,account,book,chapter,prepared,current)
    local function live()
        if type(current)~='function' then return false end
        local ok,value=pcall(current)
        return ok and value==true
    end
    if type(settings)~='table' or type(account)~='string' or NativeProtocol.id(account)~=account
        or type(book)~='table' or type(chapter)~='table' or type(prepared)~='table'
        or not live() or not safe_text(book.title) or not safe_text(book.author)
        or not safe_text(chapter.title) or book.book_id~=prepared.book_id or chapter.chapterUid~=prepared.chapter_uid
        or type(book.book_id)~='string' or NativeProtocol.id(book.book_id)~=book.book_id
        or type(chapter.chapterUid)~='string' or NativeProtocol.id(chapter.chapterUid)~=chapter.chapterUid
        or not NativeProtocol.integer(prepared.book_version,0,2147483647)
        or not NativeProtocol.integer(prepared.missing_images,0,64)
        or not hash(prepared.catalog_sha256) or not hash(prepared.reading_catalog_sha256) or not hash(prepared.source_sha256)
        or prepared.source_channel~='eink' or prepared.coordinate_source_authoritative~=false
        or type(prepared.xhtml)~='string' or #prepared.xhtml==0 or #prepared.xhtml>8*1024*1024
        or type(prepared.css)~='string' or #prepared.css>8*1024*1024 or type(prepared.assets)~='table' then
        return nil,'invalid'
    end
    local lfs=fs();local root=Path.root(settings)
    local key=content_key(account,book,chapter,prepared)
    if not lfs or not root or not key then return nil,'storage' end
    local parent=mode(lfs,settings.data_dir)
    if not parent or parent.mode~='directory' then return nil,'storage' end
    root=directory(lfs,settings.data_dir:gsub('/+$',''),'native-reader-v1')
    local account_dir=root and directory(lfs,root,Crypto.sha256_hex('native-direct-account\0'..account))
    local book_dir=account_dir and directory(lfs,account_dir,Crypto.sha256_hex('native-direct-book\0'..book.book_id))
    if not book_dir then return nil,'storage' end
    local filename='wr-chapter-'..Crypto.sha256_hex(book.book_id..'\0'..chapter.chapterUid)..'.epub'
    local text_digest=Crypto.sha256_hex(prepared.xhtml)
    for index=0,M.MAX_COPIES-1 do
        if not live() then return nil,'session_changed' end
        local dir=book_dir..'/'..key..(index==0 and '' or '-'..index)
        local created=lfs.mkdir(dir)
        local attr=mode(lfs,dir)
        if not attr or attr.mode~='directory' then return nil,'storage' end
        local path=dir..'/'..filename
        if not created then
            if verified(lfs,dir,path,book,chapter,prepared,key,text_digest) and live() then
                return {path=path,reused=true,book_version=prepared.book_version,source_sha256=prepared.source_sha256,
                    missing_images=prepared.missing_images}
            end
        else
            local local_book={book_id=book.book_id,title=book.title,author=book.author,
                bookVersion=prepared.book_version,cache_dir=dir}
            local local_chapter={chapterUid=chapter.chapterUid,title=chapter.title,chapterIdx=chapter.chapterIdx}
            local function guard()
                local directory_now=mode(lfs,dir)
                if not live() or not directory_now or directory_now.mode~='directory'
                    or directory_now.dev~=attr.dev or directory_now.ino~=attr.ino then
                    error('native_direct/session_changed',0)
                end
                return true
            end
            local ok,result=pcall(require('weread.lib.content').save_chapter_epub,settings,local_book,local_chapter,
                prepared.xhtml,prepared.assets,prepared.css,Identity.capture(local_book),nil,nil,guard)
            if not ok or result~=path or not live() then return nil,live() and 'storage' or 'session_changed' end
            local size,digest=digest_file(lfs,path)
            if not size or not archive_identity(path,book.book_id,chapter.chapterUid,prepared.book_version,text_digest)
                or not archive_content(path,book,chapter,prepared)
                or not live() or not publish_receipt(dir,key,size,digest) or not live()
                or not verified(lfs,dir,path,book,chapter,prepared,key,text_digest) then
                return nil,live() and 'storage' or 'session_changed'
            end
            return {path=path,reused=false,book_version=prepared.book_version,source_sha256=prepared.source_sha256,
                missing_images=prepared.missing_images}
        end
    end
    return nil,'storage'
end
return M

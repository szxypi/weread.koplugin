-- Isolated E-Ink-only EPUBs. A cached file is reused only with its own complete
-- receipt; corrupt or interrupted copies are left intact and never overwritten.
local Crypto=require('weread.lib.crypto')
local Identity=require('weread.lib.book_file_identity')
local Protocol=require('weread.lib.protocol')
local NativeProtocol=require('weread.lib.native_position_protocol')
local Path=require('weread.lib.native_direct_path')
local M={MAX_FILE=128*1024*1024,MAX_COPIES=100,MAX_ENTRIES=2000}
local CHUNK=65536
local OPERATION='.native-operation'
local RETIRING='.native-cleanup'
M.RETIRING=RETIRING

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
        local matches=identity and identity.book_id==book_id and identity.book_version==Identity.version(version)
            and identity.chapter_count==1 and type(opf)=='string'
            and members[Identity.PATH]:match('\ntext_digest=([a-f0-9]+)\n')==text_digest
            and opf:find('<dc:source>'..Protocol.reader_url(book_id,uid)..'</dc:source>',1,true)~=nil
        return matches and identity or nil
    end)
    return ok and result or nil
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
local function entry_payload(entry)
    return table.concat({'native-direct-entry-v1','owner='..entry.owner,'book='..entry.book_id,'chapter='..entry.chapter_uid,
        'version='..tostring(entry.book_version),'index='..(entry.chapter_idx and tostring(entry.chapter_idx) or '-'),
        'title='..entry.title,'missing='..tostring(entry.missing_images),'text='..entry.text_digest,
        'source='..entry.source_sha256,''},'\n')
end
local function valid_entry(entry,book_id,account)
    return type(entry)=='table' and type(entry.book_id)=='string' and entry.book_id==book_id
        and hash(entry.owner) and (account==nil or type(account)=='string' and NativeProtocol.id(account)==account
            and entry.owner==Crypto.sha256_hex('native-direct-account\0'..account))
        and NativeProtocol.id(entry.book_id)==entry.book_id and type(entry.chapter_uid)=='string'
        and NativeProtocol.id(entry.chapter_uid)==entry.chapter_uid
        and NativeProtocol.integer(entry.book_version,0,2147483647)
        and (entry.chapter_idx==nil or NativeProtocol.integer(entry.chapter_idx,0,1000000))
        and safe_text(entry.title) and NativeProtocol.integer(entry.missing_images,0,64)
        and hash(entry.text_digest) and hash(entry.source_sha256) and hash(entry.key)
        and NativeProtocol.integer(entry.copy,0,M.MAX_COPIES-1)
        and (entry.catalog_sha256==nil and entry.catalog_order==nil and entry.catalog_count==nil
                and entry.catalog_prev==nil and entry.catalog_next==nil
            or hash(entry.catalog_sha256) and NativeProtocol.integer(entry.catalog_count,1,20000)
                and NativeProtocol.integer(entry.catalog_order,1,entry.catalog_count)
                and (entry.catalog_order==1 and entry.catalog_prev==nil
                    or entry.catalog_order>1 and type(entry.catalog_prev)=='string'
                        and NativeProtocol.id(entry.catalog_prev)==entry.catalog_prev and entry.catalog_prev~=entry.chapter_uid)
                and (entry.catalog_order==entry.catalog_count and entry.catalog_next==nil
                    or entry.catalog_order<entry.catalog_count and type(entry.catalog_next)=='string'
                        and NativeProtocol.id(entry.catalog_next)==entry.catalog_next and entry.catalog_next~=entry.chapter_uid)
                and (not entry.catalog_prev or not entry.catalog_next or entry.catalog_prev~=entry.catalog_next))
end
M.valid_entry=valid_entry
local function read_file(lfs,path,limit)
    local attr=mode(lfs,path)
    if not attr or attr.mode~='file' or attr.size<1 or attr.size>limit then return nil end
    local file=io.open(path,'rb');if not file then return nil end
    local raw,err=file:read(limit+1);local closed=file:close()
    return not err and closed and raw and #raw==attr.size and raw or nil
end
-- Native-only bytes are a local draft aid, never proof of Web coordinates.
-- An interrupted write is rejected by its hash and never overwritten.
local RAW_SOURCE='native-source.txt'
local function save_raw(lfs,dir,entry,raw,lease,current)
    local limit=require('weread.lib.source_coordinates').MAX_BYTES
    if not lease or not lease:owns() or not current() or type(raw)~='string' or #raw<1 or #raw>limit
        or Crypto.sha256_hex(raw)~=entry.source_sha256 then return end
    local path=dir..'/'..RAW_SOURCE
    if mode(lfs,path) then return end
    local ffi=require('ffi');require('ffi/posix_h')
    if ffi.os~='Linux' and ffi.os~='OSX' then return end
    local flags=require('bit').bor(ffi.C.O_WRONLY,ffi.C.O_CREAT,ffi.C.O_CLOEXEC,
        ffi.os=='OSX' and 0x800 or 0x80,ffi.os=='OSX' and 0x100 or 0x20000)
    local fd=tonumber(ffi.C.open(path,flags,ffi.cast('int',384)))
    if fd<0 then return end
    local offset=0
    while offset<#raw and lease:owns() and current() do
        local n=tonumber(ffi.C.write(fd,ffi.cast('const char*',raw)+offset,#raw-offset))
        if n>0 then offset=offset+n elseif n>=0 or ffi.errno()~=ffi.C.EINTR then break end
    end
    if offset==#raw then ffi.C.fsync(fd) end
    ffi.C.close(fd)
end
function M.read_raw_source(file,entry)
    if type(file)~='string' or type(entry)~='table' or not hash(entry.source_sha256) then return nil end
    local dir=file:match('^(.*)/[^/]+$');local lfs=fs()
    if not lfs or not dir then return nil end
    local parent=mode(lfs,dir)
    if not parent or parent.mode~='directory' then return nil end
    local raw=read_file(lfs,dir..'/'..RAW_SOURCE,require('weread.lib.source_coordinates').MAX_BYTES)
    local after=mode(lfs,dir)
    if not after or after.mode~='directory' or after.dev~=parent.dev or after.ino~=parent.ino
        or not raw or Crypto.sha256_hex(raw)~=entry.source_sha256 then return nil end
    return raw
end
local function read_entry(lfs,dir,key,copy,book_id,account)
    local raw=read_file(lfs,dir..'/entry.txt',4096)
    if not raw then return nil end
    local payload,checksum=raw:match('^(.-)entry_digest=([a-f0-9]+)\n$')
    if not payload or not hash(checksum) or Crypto.sha256_hex(payload)~=checksum then return nil end
    local owner,book,uid,version,index,title,missing,text_digest,source=payload:match('^native%-direct%-entry%-v1\nowner=([a-f0-9]+)\nbook=([^\n]+)\nchapter=([^\n]+)\nversion=(%d+)\nindex=([^\n]+)\ntitle=([^\n]*)\nmissing=(%d+)\ntext=([a-f0-9]+)\nsource=([a-f0-9]+)\n$')
    if not book or not version or not missing or index~='-' and not index:match('^%d+$') then return nil end
    local entry={owner=owner,book_id=book,chapter_uid=uid,book_version=tonumber(version),
        chapter_idx=index~='-' and tonumber(index) or nil,title=title,missing_images=tonumber(missing),
        text_digest=text_digest,source_sha256=source,key=key,copy=copy}
    if not valid_entry(entry,book_id or entry.book_id,account) or entry_payload(entry)~=payload then return nil end
    return entry
end
local function ref_payload(entry)
    return table.concat({'native-direct-catalog-v1','owner='..entry.owner,'book='..entry.book_id,
        'chapter='..entry.chapter_uid,'content='..entry.key,'catalog='..entry.catalog_sha256,
        'order='..tostring(entry.catalog_order),'count='..tostring(entry.catalog_count),
        'previous='..(entry.catalog_prev or '-'),'next='..(entry.catalog_next or '-'),''},'\n')
end
local function read_ref(lfs,dir,entry)
    local raw=read_file(lfs,dir..'/catalog.txt',1024)
    if not raw then return nil end
    local payload,digest=raw:match('^(.-)catalog_digest=([a-f0-9]+)\n$')
    if not payload or not hash(digest) or Crypto.sha256_hex(payload)~=digest then return nil end
    local owner,book,uid,key,catalog,order,count,previous,next_uid=payload:match('^native%-direct%-catalog%-v1\nowner=([a-f0-9]+)\nbook=([^\n]+)\nchapter=([^\n]+)\ncontent=([a-f0-9]+)\ncatalog=([a-f0-9]+)\norder=(%d+)\ncount=(%d+)\nprevious=([^\n]+)\nnext=([^\n]+)\n$')
    if owner~=entry.owner or book~=entry.book_id or uid~=entry.chapter_uid or key~=entry.key then return nil end
    local result={owner=owner,book_id=book,chapter_uid=uid,key=key,catalog_sha256=catalog,
        catalog_order=tonumber(order),catalog_count=tonumber(count),catalog_prev=previous~='-' and previous or nil,
        catalog_next=next_uid~='-' and next_uid or nil}
    if not hash(catalog) or not NativeProtocol.integer(result.catalog_count,1,20000)
        or not NativeProtocol.integer(result.catalog_order,1,result.catalog_count)
        or (result.catalog_order==1)~=(result.catalog_prev==nil)
        or (result.catalog_order==result.catalog_count)~=(result.catalog_next==nil)
        or result.catalog_prev and (NativeProtocol.id(result.catalog_prev)~=result.catalog_prev or result.catalog_prev==uid)
        or result.catalog_next and (NativeProtocol.id(result.catalog_next)~=result.catalog_next or result.catalog_next==uid)
        or result.catalog_prev and result.catalog_next and result.catalog_prev==result.catalog_next
        or ref_payload(result)~=payload then return nil end
    return result
end
local function attach_ref(lfs,dir,entry)
    local ref=read_ref(lfs,dir,entry)
    if ref then
        entry.catalog_sha256,entry.catalog_order,entry.catalog_count=ref.catalog_sha256,ref.catalog_order,ref.catalog_count
        entry.catalog_prev,entry.catalog_next=ref.catalog_prev,ref.catalog_next
    end
    return entry
end
local function publish_ref(lfs,dir,entry)
    if not entry.catalog_sha256 then return true end
    local existing=read_ref(lfs,dir,entry)
    if existing then return ref_payload(existing)==ref_payload(entry) end
    if mode(lfs,dir..'/catalog.txt') or mode(lfs,dir..'/catalog.txt.part') then return false end
    local payload=ref_payload(entry);local temp=dir..'/catalog.txt.part'
    local file=io.open(temp,'wb');if not file then return false end
    local ok=file:write(payload..'catalog_digest='..Crypto.sha256_hex(payload)..'\n')
    local closed=file:close()
    if not ok or not closed then os.remove(temp);return false end
    if not os.rename(temp,dir..'/catalog.txt') then os.remove(temp);return false end
    local saved=read_ref(lfs,dir,entry)
    return saved~=nil and ref_payload(saved)==payload
end
local function publish_entry(lfs,dir,entry,account)
    local existing=read_entry(lfs,dir,entry.key,entry.copy,entry.book_id,account)
    if existing then
        return existing.chapter_uid==entry.chapter_uid and existing.book_version==entry.book_version
            and existing.text_digest==entry.text_digest and existing.source_sha256==entry.source_sha256
            and existing.title==entry.title and existing.missing_images==entry.missing_images
    end
    if mode(lfs,dir..'/entry.txt') or mode(lfs,dir..'/entry.txt.part') then return false end
    local payload=entry_payload(entry)
    local file=io.open(dir..'/entry.txt.part','wb');if not file then return false end
    local ok=file:write(payload..'entry_digest='..Crypto.sha256_hex(payload)..'\n')
    local closed=file:close()
    if not ok or not closed then os.remove(dir..'/entry.txt.part');return false end
    if not os.rename(dir..'/entry.txt.part',dir..'/entry.txt') then os.remove(dir..'/entry.txt.part');return false end
    return read_entry(lfs,dir,entry.key,entry.copy,entry.book_id,account)~=nil
end
local function existing_book_dir(settings,account,book_id)
    local lfs=fs();local root=Path.root(settings)
    if not lfs or not root or type(account)~='string' or NativeProtocol.id(account)~=account
        or type(book_id)~='string' or NativeProtocol.id(book_id)~=book_id then return nil end
    local account_dir=root..'/'..Crypto.sha256_hex('native-direct-account\0'..account)
    local book_dir=account_dir..'/'..Crypto.sha256_hex('native-direct-book\0'..book_id)
    for _,path in ipairs({settings.data_dir,root,account_dir,book_dir}) do
        local attr=mode(lfs,path)
        if not attr or attr.mode~='directory' then return nil end
    end
    return lfs,book_dir
end
function M.book_directory(settings,account,book_id)
    local _,path=existing_book_dir(settings,account,book_id)
    return path
end
function M.acquire(settings,account,book_id)
    local _,path=existing_book_dir(settings,account,book_id)
    if not path then return nil,'absent' end
    return require('weread.lib.file_lease').open(path..'/'..OPERATION,{create=true,empty=true})
end
local function name_of(entry)
    return entry.key..(entry.copy==0 and '' or '-'..tostring(entry.copy))
end
local function filename(book_id,uid)
    return 'wr-chapter-'..Crypto.sha256_hex(book_id..'\0'..uid)..'.epub'
end

-- A bounded, account-scoped hint for shelf badges and filters. It is not an
-- opening receipt: selected chapters still pass the complete Cache.open check.
local function presence_path(book_dir)
    local parent,book_hash=book_dir:match('^(.*)/([^/]+)$')
    return parent and hash(book_hash) and parent..'/.native-presence-'..book_hash or nil,parent
end
local function candidate_present(lfs,book_dir,entry)
    local dir=book_dir..'/'..name_of(entry)
    local attr=mode(lfs,dir)
    if not attr or attr.mode~='directory' then return false end
    if mode(lfs,dir..'/'..RETIRING) then return false end
    local file=mode(lfs,dir..'/'..filename(entry.book_id,entry.chapter_uid))
    local receipt=read_file(lfs,dir..'/receipt.txt',256)
    local key,size,digest
    if receipt then key,size,digest=receipt:match('^native%-direct%-v1\ncontent=([a-f0-9]+)\nsize=(%d+)\ndigest=([a-f0-9]+)\n$') end
    return file~=nil and file.mode=='file' and file.size>0 and file.size<=M.MAX_FILE
        and key==entry.key and size==tostring(file.size) and hash(digest) or false
end
function M.present(settings,account,book_id)
    local lfs,book_dir=existing_book_dir(settings,account,book_id)
    if not lfs then return false end
    local marker=presence_path(book_dir)
    local raw=marker and read_file(lfs,marker,256)
    local key,copy
    if raw then key,copy=raw:match('^native%-presence%-v1\nkey=([a-f0-9]+)\ncopy=(%d+)\n$') end
    local numeric=copy and tonumber(copy)
    if not hash(key) or not NativeProtocol.integer(numeric,0,M.MAX_COPIES-1) or tostring(numeric)~=copy then return false end
    copy=numeric
    local dir=book_dir..'/'..key..(copy==0 and '' or '-'..tostring(copy))
    local attr=mode(lfs,dir)
    local entry=attr and attr.mode=='directory' and read_entry(lfs,dir,key,copy,book_id,account)
    return entry and candidate_present(lfs,book_dir,entry) or false
end
local function save_presence_unsafe(settings,account,book_id,entry,current)
    if type(current)~='function' or current()~=true or not valid_entry(entry,book_id,account) then return false end
    local lfs,book_dir=existing_book_dir(settings,account,book_id)
    if not lfs then return false end
    local marker,parent=presence_path(book_dir)
    local owner=parent and mode(lfs,parent)
    if not marker or not owner or owner.mode~='directory' then return false end
    local ok,output=pcall(function() return require('weread.lib.notes_export_file').create(parent,'native-presence','json') end)
    if not ok or not output then return false end
    local raw='native-presence-v1\nkey='..entry.key..'\ncopy='..tostring(entry.copy)..'\n'
    local complete=false
    local wrote,result=pcall(function()
        local written=output:write(raw) and output:accept(#raw)
        local fresh=mode(lfs,parent)
        if not written or current()~=true or not fresh or fresh.mode~='directory'
            or fresh.dev~=owner.dev or fresh.ino~=owner.ino or not output:owns() then return false end
        complete=os.rename(output.path,marker)==true
        return complete
    end)
    if not complete then pcall(output.abort,output) end
    return wrote and result==true
end
local function save_presence(...)
    local ok,result=pcall(save_presence_unsafe,...)
    return ok and result==true
end

-- List bounded metadata only; a selected file is fully checked by open().
-- Missing/corrupt sidecars and old pre-index files are left untouched.
function M.list(settings,account,book_id,current)
    local lfs,book_dir=existing_book_dir(settings,account,book_id)
    if not lfs then return {} end
    local ok,result=pcall(function()
        local rows,count={},0
        for name in lfs.dir(book_dir) do
            if name~='.' and name~='..' and name~=OPERATION then
                count=count+1;if count>M.MAX_ENTRIES then return nil end
                if type(current)~='function' or current()~=true then return nil end
                local key,suffix=name:match('^([a-f0-9]+)%-(%d+)$')
                if not key then key=name;suffix='0' end
                local copy=tonumber(suffix)
                if hash(key) and copy and tostring(copy)==suffix and copy<M.MAX_COPIES then
                    local dir=book_dir..'/'..name;local attr=mode(lfs,dir)
                    local entry=attr and attr.mode=='directory' and not mode(lfs,dir..'/'..RETIRING)
                        and read_entry(lfs,dir,key,copy,book_id,account)
                    local file=entry and mode(lfs,dir..'/'..filename(book_id,entry.chapter_uid))
                    if entry and file and file.mode=='file' and file.size>0 and file.size<=M.MAX_FILE then
                        rows[#rows+1]=attach_ref(lfs,dir,entry)
                    end
                end
            end
        end
        table.sort(rows,function(a,b)
            if a.chapter_idx~=b.chapter_idx then return (a.chapter_idx or 1000001)<(b.chapter_idx or 1000001) end
            if a.title~=b.title then return a.title<b.title end
            if a.chapter_uid~=b.chapter_uid then return a.chapter_uid<b.chapter_uid end
            if a.book_version~=b.book_version then return a.book_version>b.book_version end
            if a.key~=b.key then return a.key<b.key end
            return a.copy<b.copy
        end)
        return rows
    end)
    if ok and result and not M.present(settings,account,book_id) then
        for _,entry in ipairs(result) do
            if candidate_present(lfs,book_dir,entry) then save_presence(settings,account,book_id,entry,current);break end
        end
    end
    return ok and result or nil
end

-- Count every directory entry, including damaged copies and staging files:
-- the offline index refuses to scan beyond MAX_ENTRIES even when some entries
-- are not usable chapters. Never delete anything to make room.
function M.remaining(settings,account,book_id,current)
    if type(current)~='function' or current()~=true then return nil end
    local lfs,book_dir=existing_book_dir(settings,account,book_id)
    if not lfs then return M.MAX_ENTRIES end
    local ok,count=pcall(function()
        local total=0
        for name in lfs.dir(book_dir) do
            if name~='.' and name~='..' and name~=OPERATION then
                total=total+1
                if total>M.MAX_ENTRIES then return nil end
                -- A capacity scan reads names only. Check authorization at
                -- intervals and before returning the count to the downloader.
                if total%32==0 and current()~=true then return nil end
            end
        end
        return current()==true and total or nil
    end)
    return ok and count and M.MAX_ENTRIES-count or nil
end

function M.open(settings,account,book_id,entry,current)
    if not valid_entry(entry,book_id,account) or type(current)~='function' or current()~=true then return nil end
    local lfs,book_dir=existing_book_dir(settings,account,book_id)
    if not lfs then return nil end
    local dir=book_dir..'/'..name_of(entry);local attr=mode(lfs,dir)
    if not attr or attr.mode~='directory' or mode(lfs,dir..'/'..RETIRING) then return nil end
    local actual=read_entry(lfs,dir,entry.key,entry.copy,book_id,account)
    if not actual or entry_payload(actual)~=entry_payload(entry) then return nil end
    if entry.catalog_sha256 then
        local ref=read_ref(lfs,dir,actual)
        if not ref or ref_payload(ref)~=ref_payload(entry) then return nil end
    end
    local path=dir..'/'..filename(book_id,entry.chapter_uid)
    local receipt=read_file(lfs,dir..'/receipt.txt',256)
    local key,size,digest
    if receipt then key,size,digest=receipt:match('^native%-direct%-v1\ncontent=([a-f0-9]+)\nsize=(%d+)\ndigest=([a-f0-9]+)\n$') end
    if key~=entry.key or not size or not hash(digest) then return nil end
    local actual_size,actual_digest=digest_file(lfs,path)
    if not actual_size or tostring(actual_size)~=size or actual_digest~=digest then return nil end
    local identity=archive_identity(path,book_id,entry.chapter_uid,entry.book_version,entry.text_digest)
    if not identity or current()~=true then return nil end
    if not M.present(settings,account,book_id) then save_presence(settings,account,book_id,entry,current) end
    return {path=path,book_version=entry.book_version,source_sha256=entry.source_sha256,
        missing_images=entry.missing_images,file_id=identity.file_id}
end

-- Resolve an open file back to a verified, account-bound chapter. The path is
-- only an index: the receipt and EPUB identity are checked independently.
function M.identify(settings,account,path,current)
    local root=Path.root(settings)
    if not root or type(path)~='string' or path:sub(1,#root+1)~=root..'/'
        or type(account)~='string' or NativeProtocol.id(account)~=account then return nil end
    local owner,book_hash,name,file=path:sub(#root+2):match('^([^/]+)/([^/]+)/([^/]+)/([^/]+)$')
    if owner~=Crypto.sha256_hex('native-direct-account\0'..account) or not hash(book_hash) then return nil end
    local key,suffix=name:match('^([a-f0-9]+)%-(%d+)$')
    if not key then key=name;suffix='0' end
    local copy=tonumber(suffix)
    if not hash(key) or not copy or tostring(copy)~=suffix or copy>=M.MAX_COPIES then return nil end
    local lfs=fs();local dir=root..'/'..owner..'/'..book_hash..'/'..name
    local attr=lfs and mode(lfs,dir)
    if not attr or attr.mode~='directory' then return nil end
    local entry=read_entry(lfs,dir,key,copy,nil,account)
    if not entry or book_hash~=Crypto.sha256_hex('native-direct-book\0'..entry.book_id)
        or file~=filename(entry.book_id,entry.chapter_uid) then return nil end
    attach_ref(lfs,dir,entry)
    local checked=M.open(settings,account,entry.book_id,entry,current)
    if checked then entry.file_id=checked.file_id end
    return checked and entry or nil
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
        or chapter.chapterIdx~=nil and not NativeProtocol.integer(chapter.chapterIdx,0,1000000)
        or not (chapter.catalog_order==nil and chapter.catalog_count==nil
                and chapter.catalog_prev==nil and chapter.catalog_next==nil
            or NativeProtocol.integer(chapter.catalog_count,1,20000)
                and NativeProtocol.integer(chapter.catalog_order,1,chapter.catalog_count)
                and (chapter.catalog_order==1 and chapter.catalog_prev==nil
                    or chapter.catalog_order>1 and type(chapter.catalog_prev)=='string'
                        and NativeProtocol.id(chapter.catalog_prev)==chapter.catalog_prev and chapter.catalog_prev~=chapter.chapterUid)
                and (chapter.catalog_order==chapter.catalog_count and chapter.catalog_next==nil
                    or chapter.catalog_order<chapter.catalog_count and type(chapter.catalog_next)=='string'
                        and NativeProtocol.id(chapter.catalog_next)==chapter.catalog_next and chapter.catalog_next~=chapter.chapterUid)
                and (not chapter.catalog_prev or not chapter.catalog_next or chapter.catalog_prev~=chapter.catalog_next))
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
    local lease,reason=M.acquire(settings,account,book.book_id)
    if not lease and reason~='unsupported' then return nil,live() and 'storage' or 'session_changed' end
    local ok,first,second=pcall(function()
    local chapter_file=filename(book.book_id,chapter.chapterUid)
    local text_digest=Crypto.sha256_hex(prepared.xhtml)
    for index=0,M.MAX_COPIES-1 do
        if not live() then return nil,'session_changed' end
        local dir=book_dir..'/'..key..(index==0 and '' or '-'..index)
        local created=lfs.mkdir(dir)
        local attr=mode(lfs,dir)
        if not attr or attr.mode~='directory' then return nil,'storage' end
        -- A power loss after the last cleanup marker was removed can leave an
        -- empty owned slot. rmdir never removes a slot containing any data.
        if not created and lease and lease:owns() and lfs.rmdir(dir) then
            created=lfs.mkdir(dir);attr=mode(lfs,dir)
            if not created or not attr or attr.mode~='directory' then return nil,'storage' end
        end
        local path=dir..'/'..chapter_file
        local entry={owner=Crypto.sha256_hex('native-direct-account\0'..account),
            book_id=book.book_id,chapter_uid=chapter.chapterUid,book_version=prepared.book_version,
            chapter_idx=chapter.chapterIdx,title=chapter.title,missing_images=prepared.missing_images,
            text_digest=text_digest,source_sha256=prepared.source_sha256,key=key,copy=index}
        if chapter.catalog_order then
            entry.catalog_sha256,entry.catalog_order,entry.catalog_count=prepared.reading_catalog_sha256,
                chapter.catalog_order,chapter.catalog_count
            entry.catalog_prev,entry.catalog_next=chapter.catalog_prev,chapter.catalog_next
        end
        if not created then
            if not mode(lfs,dir..'/'..RETIRING) and verified(lfs,dir,path,book,chapter,prepared,key,text_digest) and live()
                and publish_entry(lfs,dir,entry,account) and publish_ref(lfs,dir,entry) and live() then
                pcall(save_raw,lfs,dir,entry,prepared.source_raw,lease,live)
                save_presence(settings,account,book.book_id,entry,live)
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
                or not verified(lfs,dir,path,book,chapter,prepared,key,text_digest)
                or not publish_entry(lfs,dir,entry,account) or not publish_ref(lfs,dir,entry) or not live() then
                return nil,live() and 'storage' or 'session_changed'
            end
            save_presence(settings,account,book.book_id,entry,live)
            pcall(save_raw,lfs,dir,entry,prepared.source_raw,lease,live)
            return {path=path,reused=false,book_version=prepared.book_version,source_sha256=prepared.source_sha256,
                missing_images=prepared.missing_images}
        end
    end
    return nil,'storage'
    end)
    if lease then lease:release() end
    if not ok then return nil,live() and 'storage' or 'session_changed' end
    return first,second
end
return M

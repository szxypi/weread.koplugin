-- Isolated E-Ink-only EPUBs. A cached file is reused only with its own complete
-- receipt; corrupt or interrupted copies are left intact and never overwritten.
local Crypto=require('weread.lib.crypto')
local Identity=require('weread.lib.book_file_identity')
local Protocol=require('weread.lib.protocol')
local NativeProtocol=require('weread.lib.native_position_protocol')
local Path=require('weread.lib.native_direct_path')
local Archive=require('weread.lib.source_archive')
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
local function checked_identity(raw,book_id,version,text_digest)
    local identity=Identity.decode(raw)
    if identity and identity.book_id==book_id and identity.book_version==Identity.version(version)
        and identity.chapter_count==1 and raw:match('\ntext_digest=([a-f0-9]+)\n')==text_digest then return identity end
end
local function matches_source(opf,book_id,uid)
    return type(opf)=='string' and opf:find('<dc:source>'..Protocol.reader_url(book_id,uid)..'</dc:source>',1,true)~=nil
end
local function archive_identity(path,book_id,uid,version,text_digest)
    local ok,result=pcall(function()
        local members=Archive.read(path,{[Identity.PATH]=Identity.MAX_BYTES,['OEBPS/content.opf']=1024*1024})
        if members and matches_source(members['OEBPS/content.opf'],book_id,uid) then
            return checked_identity(members[Identity.PATH],book_id,version,text_digest)
        end
    end)
    return ok and result or nil
end
local function archive_members(book,chapter,prepared,text_digest)
    local rendered=require('weread.lib.content').single_chapter_xhtml(book,chapter,prepared.xhtml)
    if #rendered>8*1024*1024 then return nil end
    local identity_member={maximum=Identity.MAX_BYTES}
    identity_member.validate=function(raw)
        local identity=checked_identity(raw,book.book_id,prepared.book_version,text_digest)
        identity_member.file_id=identity and identity.file_id
        return identity~=nil
    end
    local wanted={
        [Identity.PATH]=identity_member,
        ['OEBPS/content.opf']={maximum=1024*1024,validate=function(raw)
            return matches_source(raw,book.book_id,chapter.chapterUid)
        end},
        ['mimetype']={maximum=128,bytes='application/epub+zip'},
        ['OEBPS/text/chapter.xhtml']={maximum=8*1024*1024,bytes=rendered},
        ['OEBPS/style.css']={maximum=8*1024*1024,bytes=prepared.css},
    }
    for _,asset in ipairs(prepared.assets) do
        if #asset.data>8*1024*1024 then return nil end
        wanted['OEBPS/'..asset.href]={maximum=8*1024*1024,bytes=asset.data}
    end
    return wanted,identity_member
end
local function verified(lfs,dir,path,key,wanted)
    local proof=dir..'/receipt.txt'
    local attr=mode(lfs,proof)
    if not attr or attr.mode~='file' or attr.size>256 then return false end
    local file=io.open(proof,'rb');if not file then return false end
    local text,err=file:read(257);local closed=file:close()
    if err or not closed or not text then return false end
    local saved_key,size,digest=text:match('^native%-direct%-v1\ncontent=([a-f0-9]+)\nsize=(%d+)\ndigest=([a-f0-9]+)\n$')
    if saved_key~=key or not size or #digest~=64 then return false end
    local actual,hash=digest_file(lfs,path)
    return actual~=nil and tostring(actual)==size and hash==digest and Archive.verify_members(path,wanted)
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
local function read_entry(lfs,dir,key,copy,book_id,account,chapter_set)
    local raw=read_file(lfs,dir..'/entry.txt',4096)
    if not raw then return nil end
    local payload,checksum=raw:match('^(.-)entry_digest=([a-f0-9]+)\n$')
    if not payload or not hash(checksum) then return nil end
    local owner,book,uid,version,index,title,missing,text_digest,source=payload:match('^native%-direct%-entry%-v1\nowner=([a-f0-9]+)\nbook=([^\n]+)\nchapter=([^\n]+)\nversion=(%d+)\nindex=([^\n]+)\ntitle=([^\n]*)\nmissing=(%d+)\ntext=([a-f0-9]+)\nsource=([a-f0-9]+)\n$')
    if not book or not version or not missing or index~='-' and not index:match('^%d+$')
        or chapter_set and chapter_set[uid]~=true then return nil end
    if Crypto.sha256_hex(payload)~=checksum then return nil end
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
local function attach_ref(entry,ref)
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
        if existing.chapter_uid==entry.chapter_uid and existing.book_version==entry.book_version
            and existing.text_digest==entry.text_digest and existing.source_sha256==entry.source_sha256
            and existing.title==entry.title and existing.missing_images==entry.missing_images then return existing end
        return nil
    end
    if mode(lfs,dir..'/entry.txt') or mode(lfs,dir..'/entry.txt.part') then return false end
    local payload=entry_payload(entry)
    local file=io.open(dir..'/entry.txt.part','wb');if not file then return false end
    local ok=file:write(payload..'entry_digest='..Crypto.sha256_hex(payload)..'\n')
    local closed=file:close()
    if not ok or not closed then os.remove(dir..'/entry.txt.part');return false end
    if not os.rename(dir..'/entry.txt.part',dir..'/entry.txt') then os.remove(dir..'/entry.txt.part');return false end
    local saved=read_entry(lfs,dir,entry.key,entry.copy,entry.book_id,account)
    return saved and entry_payload(saved)==payload and saved or nil
end

local function published_copy(path,reused,saved,reference,file_id)
    saved.file_id=file_id
    return {path=path,reused=reused,book_version=saved.book_version,source_sha256=saved.source_sha256,
        missing_images=saved.missing_images,file_id=file_id,saved_entry=attach_ref(saved,reference)}
end
local function owned_book_dir(settings,root,owner,book_hash)
    local lfs=fs()
    if not lfs then return nil end
    local account_dir=root..'/'..owner
    local book_dir=account_dir..'/'..book_hash
    for _,path in ipairs({settings.data_dir,root,account_dir,book_dir}) do
        local attr=mode(lfs,path)
        if not attr or attr.mode~='directory' then return nil end
    end
    return lfs,book_dir
end
local function existing_book_dir(settings,account,book_id)
    local root=Path.root(settings)
    if not root or type(account)~='string' or NativeProtocol.id(account)~=account
        or type(book_id)~='string' or NativeProtocol.id(book_id)~=book_id then return nil end
    return owned_book_dir(settings,root,Crypto.sha256_hex('native-direct-account\0'..account),
        Crypto.sha256_hex('native-direct-book\0'..book_id))
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
local function is_chapter_file(attr)
    return attr and attr.mode=='file' and attr.size>0 and attr.size<=M.MAX_FILE
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
    return is_chapter_file(file)
        and key==entry.key and size==tostring(file.size) and hash(digest) or false
end
local function marker_present(lfs,book_dir,book_id,account,verified_entry)
    local marker=presence_path(book_dir)
    local raw=marker and read_file(lfs,marker,256)
    local key,copy
    if raw then key,copy=raw:match('^native%-presence%-v1\nkey=([a-f0-9]+)\ncopy=(%d+)\n$') end
    local numeric=copy and tonumber(copy)
    if not hash(key) or not NativeProtocol.integer(numeric,0,M.MAX_COPIES-1) or tostring(numeric)~=copy then return false end
    copy=numeric
    if verified_entry and key==verified_entry.key and copy==verified_entry.copy then return true end
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

local function read_list_entry(lfs,book_dir,name,book_id,account,selected_file,chapter_set)
    local key,suffix=name:match('^([a-f0-9]+)%-(%d+)$')
    if not key then key=name;suffix='0' end
    local copy=tonumber(suffix)
    if not hash(key) or not copy or tostring(copy)~=suffix or copy>=M.MAX_COPIES then return nil end
    local dir=book_dir..'/'..name
    local attr=mode(lfs,dir)
    -- The filename can rule out unrelated copies, but the entry must still
    -- identify the requested chapter.
    if not attr or attr.mode~='directory'
        or selected_file and not is_chapter_file(mode(lfs,dir..selected_file))
        or mode(lfs,dir..'/'..RETIRING) then return nil end
    return read_entry(lfs,dir,key,copy,book_id,account,chapter_set),dir
end

-- Downloaded books only need one usable copy. Check the directory limit
-- before reading entries, then stop at the first match without loading its catalog.
local function repair_presence(lfs,book_dir,settings,account,book_id,current)
    local ok,available=pcall(function()
        if current()~=true then return false end
        local names={}
        for name in lfs.dir(book_dir) do
            if name~='.' and name~='..' and name~=OPERATION then
                if #names>=M.MAX_ENTRIES then return false end
                names[#names+1]=name
                if #names%32==0 and current()~=true then return false end
            end
        end
        if current()~=true then return false end
        for index,name in ipairs(names) do
            if index%32==0 and current()~=true then return false end
            local entry=read_list_entry(lfs,book_dir,name,book_id,account)
            if entry and candidate_present(lfs,book_dir,entry) then
                save_presence(settings,account,book_id,entry,current)
                return current()==true
            end
        end
        return false
    end)
    return ok and available==true
end

-- Directory existence can rule out a cache before reading any marker files.
-- Repair callers still provide a live guard for the scan and publication.
function M.present(settings,account,book_id,repair_current,allow_read)
    local lfs,book_dir=existing_book_dir(settings,account,book_id)
    if not lfs or allow_read and allow_read()~=true then return false end
    if marker_present(lfs,book_dir,book_id,account) then return true end
    return type(repair_current)=='function'
        and repair_presence(lfs,book_dir,settings,account,book_id,repair_current)
end

-- List bounded metadata only; a selected file is fully checked by open(). A
-- full listing also returns whether it found a copy, even if its marker failed to save.
-- Missing/corrupt sidecars and old pre-index files are left untouched.
-- A single chapter uses its filename; a set is matched against entry records.
function M.list(settings,account,book_id,current,selection)
    local chapter_uid=type(selection)=='string' and selection
    local chapter_set=type(selection)=='table' and selection
    if selection~=nil and not chapter_set and (not chapter_uid or NativeProtocol.id(chapter_uid)~=chapter_uid) then
        return nil
    end
    local lfs,book_dir=existing_book_dir(settings,account,book_id)
    if not lfs then return {} end
    local selected_file=chapter_uid and '/'..filename(book_id,chapter_uid)
    local ok,result,available=pcall(function()
        if type(current)~='function' or current()~=true then return nil end
        local rows,count={},0
        for name in lfs.dir(book_dir) do
            if name~='.' and name~='..' and name~=OPERATION then
                count=count+1;if count>M.MAX_ENTRIES then return nil end
                -- Metadata reads are local; recheck the live grant in bounded
                -- groups and before delivering any rows to the caller.
                if count%32==0 and current()~=true then return nil end
                local entry,dir=read_list_entry(lfs,book_dir,name,book_id,account,selected_file,chapter_set)
                if entry and (not chapter_uid or entry.chapter_uid==chapter_uid) then
                    local file=mode(lfs,dir..(selected_file or '/'..filename(book_id,entry.chapter_uid)))
                    if is_chapter_file(file) then rows[#rows+1]=attach_ref(entry,read_ref(lfs,dir,entry)) end
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
        -- A full listing can repair the badge from any usable chapter.
        -- Opening a verified result can also repair its presence marker.
        local present
        if selection==nil then
            present=M.present(settings,account,book_id)
            if not present then
                if current()~=true then return nil end
                for index,entry in ipairs(rows) do
                    if index%32==0 and current()~=true then return nil end
                    if candidate_present(lfs,book_dir,entry) then
                        present=true;save_presence(settings,account,book_id,entry,current);break
                    end
                end
            end
        end
        if current()~=true then return nil end
        return rows,present
    end)
    if ok then return result,available end
end

local function reserved_room(capacity,lfs,book_dir)
    if capacity.book_dir~=book_dir or not capacity.lease:owns() then return nil end
    local owner=mode(lfs,book_dir)
    if owner and owner.mode=='directory' and owner.dev==capacity.dev and owner.ino==capacity.ino then
        return capacity.room
    end
end

-- Count every directory entry, including damaged copies and staging files.
function M.remaining(settings,account,book_id,current,capacity)
    if type(current)~='function' or current()~=true then return nil end
    local lfs,book_dir=existing_book_dir(settings,account,book_id)
    if capacity then return reserved_room(capacity,lfs,book_dir) end
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

-- The batch owns the same lease used by individual saves and cleanup.
-- Count once after acquiring it, then charge each newly created slot.
function M.begin_capacity(settings,account,book_id,current)
    local lease,reason=M.acquire(settings,account,book_id)
    if not lease then return nil,reason end
    local ok,capacity=pcall(function()
        local lfs,book_dir=existing_book_dir(settings,account,book_id)
        if not lfs or lease.path~=book_dir..'/'..OPERATION then return nil end
        local owner=mode(lfs,book_dir)
        if not owner or owner.mode~='directory' then return nil end
        local scope={book_dir=book_dir,lease=lease,dev=owner.dev,ino=owner.ino}
        scope.room=M.remaining(settings,account,book_id,current)
        if reserved_room(scope,lfs,book_dir)~=nil then return scope end
    end)
    if ok and capacity then return capacity end
    lease:release()
    return nil,'unavailable'
end

-- The caller supplies the entry read from this exact account directory.
local function verify_open(settings,account,lfs,book_dir,dir,entry,current)
    local path=dir..'/'..filename(entry.book_id,entry.chapter_uid)
    local receipt=read_file(lfs,dir..'/receipt.txt',256)
    local key,size,digest
    if receipt then key,size,digest=receipt:match('^native%-direct%-v1\ncontent=([a-f0-9]+)\nsize=(%d+)\ndigest=([a-f0-9]+)\n$') end
    if key~=entry.key or not size or not hash(digest) then return nil end
    local actual_size,actual_digest=digest_file(lfs,path)
    if not actual_size or tostring(actual_size)~=size or actual_digest~=digest then return nil end
    local identity=archive_identity(path,entry.book_id,entry.chapter_uid,entry.book_version,entry.text_digest)
    if not identity or current()~=true or mode(lfs,dir..'/'..RETIRING) then return nil end
    if not marker_present(lfs,book_dir,entry.book_id,account,entry) then
        save_presence(settings,account,entry.book_id,entry,current)
    end
    return {path=path,book_version=entry.book_version,source_sha256=entry.source_sha256,
        missing_images=entry.missing_images,file_id=identity.file_id}
end

-- Callers that also need the chapter identity can take the verified entry
-- from this same check, including the catalog reference it compared.
function M.open(settings,account,book_id,entry,current,with_entry)
    if not valid_entry(entry,book_id,account) or type(current)~='function' or current()~=true then return nil end
    local lfs,book_dir=existing_book_dir(settings,account,book_id)
    if not lfs then return nil end
    local dir=book_dir..'/'..name_of(entry);local attr=mode(lfs,dir)
    if not attr or attr.mode~='directory' or mode(lfs,dir..'/'..RETIRING) then return nil end
    local actual=read_entry(lfs,dir,entry.key,entry.copy,book_id,account)
    if not actual or entry_payload(actual)~=entry_payload(entry) then return nil end
    local ref
    if entry.catalog_sha256 then
        ref=read_ref(lfs,dir,actual)
        if not ref or ref_payload(ref)~=ref_payload(entry) then return nil end
    end
    local opened=verify_open(settings,account,lfs,book_dir,dir,actual,current)
    if not opened then return nil end
    if with_entry then
        actual.file_id=opened.file_id
        return opened,attach_ref(actual,ref)
    end
    return opened
end

-- Resolve an open file back to a verified, account-bound chapter. The path is
-- only an index: the receipt and EPUB identity are checked independently.
function M.identify(settings,account,path,current)
    local root=Path.root(settings)
    if not root or type(path)~='string' or path:sub(1,#root+1)~=root..'/'
        or type(account)~='string' or NativeProtocol.id(account)~=account
        or type(current)~='function' or current()~=true then return nil end
    local owner,book_hash,name,file=path:sub(#root+2):match('^([^/]+)/([^/]+)/([^/]+)/([^/]+)$')
    if owner~=Crypto.sha256_hex('native-direct-account\0'..account) or not hash(book_hash) then return nil end
    local key,suffix=name:match('^([a-f0-9]+)%-(%d+)$')
    if not key then key=name;suffix='0' end
    local copy=tonumber(suffix)
    if not hash(key) or not copy or tostring(copy)~=suffix or copy>=M.MAX_COPIES
        or copy==0 and name~=key then return nil end
    local lfs,book_dir=owned_book_dir(settings,root,owner,book_hash)
    if not lfs then return nil end
    local dir=book_dir..'/'..name
    local attr=mode(lfs,dir)
    if not attr or attr.mode~='directory' or mode(lfs,dir..'/'..RETIRING) then return nil end
    local entry=read_entry(lfs,dir,key,copy,nil,account)
    if not entry or book_hash~=Crypto.sha256_hex('native-direct-book\0'..entry.book_id)
        or file~=filename(entry.book_id,entry.chapter_uid) then return nil end
    local ref=read_ref(lfs,dir,entry)
    local opened=verify_open(settings,account,lfs,book_dir,dir,entry,current)
    if not opened then return nil end
    entry.file_id=opened.file_id
    return attach_ref(entry,ref)
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

function M.publish(settings,account,book,chapter,prepared,current,capacity)
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
    local book_dir,lease
    if capacity then
        book_dir=M.book_directory(settings,account,book.book_id)
        local room=reserved_room(capacity,lfs,book_dir)
        if not room or room<1 then return nil,live() and 'storage' or 'session_changed' end
        lease=capacity.lease
    else
        local parent=mode(lfs,settings.data_dir)
        if not parent or parent.mode~='directory' then return nil,'storage' end
        root=directory(lfs,settings.data_dir:gsub('/+$',''),'native-reader-v1')
        local account_dir=root and directory(lfs,root,Crypto.sha256_hex('native-direct-account\0'..account))
        book_dir=account_dir and directory(lfs,account_dir,Crypto.sha256_hex('native-direct-book\0'..book.book_id))
        if not book_dir then return nil,'storage' end
        local reason
        lease,reason=M.acquire(settings,account,book.book_id)
        if not lease and reason~='unsupported' then return nil,live() and 'storage' or 'session_changed' end
    end
    local function can_publish()
        return live() and (not capacity or reserved_room(capacity,lfs,book_dir)~=nil)
    end
    local ok,first,second=pcall(function()
    local chapter_file=filename(book.book_id,chapter.chapterUid)
    local text_digest=Crypto.sha256_hex(prepared.xhtml)
    local wanted,identity_member=archive_members(book,chapter,prepared,text_digest)
    if not wanted then return nil,'storage' end
    for index=0,M.MAX_COPIES-1 do
        if not live() then return nil,'session_changed' end
        if capacity and reserved_room(capacity,lfs,book_dir)==nil then return nil,'storage' end
        local dir=book_dir..'/'..key..(index==0 and '' or '-'..index)
        local created=lfs.mkdir(dir)
        if created and capacity then capacity.room=capacity.room-1 end
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
            if not mode(lfs,dir..'/'..RETIRING) and verified(lfs,dir,path,key,wanted) and can_publish() then
                local saved=publish_entry(lfs,dir,entry,account)
                if saved and publish_ref(lfs,dir,entry) and can_publish() then
                    pcall(save_raw,lfs,dir,entry,prepared.source_raw,lease,can_publish)
                    save_presence(settings,account,book.book_id,entry,can_publish)
                    return published_copy(path,true,saved,entry,identity_member.file_id)
                end
            end
        else
            local local_book={book_id=book.book_id,title=book.title,author=book.author,
                bookVersion=prepared.book_version,cache_dir=dir}
            local local_chapter={chapterUid=chapter.chapterUid,title=chapter.title,chapterIdx=chapter.chapterIdx}
            local function guard()
                local directory_now=mode(lfs,dir)
                if not can_publish() or not directory_now or directory_now.mode~='directory'
                    or directory_now.dev~=attr.dev or directory_now.ino~=attr.ino then
                    error('native_direct/session_changed',0)
                end
                return true
            end
            local ok,result=pcall(require('weread.lib.content').save_chapter_epub,settings,local_book,local_chapter,
                prepared.xhtml,prepared.assets,prepared.css,Identity.capture(local_book),nil,nil,guard)
            if not ok or result~=path or not can_publish() then return nil,live() and 'storage' or 'session_changed' end
            -- The receipt and its EPUB are checked together before the entry
            -- makes this copy available to the offline reader.
            local size,digest=digest_file(lfs,path)
            if not size or not can_publish() or not publish_receipt(dir,key,size,digest) or not can_publish()
                or not verified(lfs,dir,path,key,wanted) or not can_publish() then
                return nil,live() and 'storage' or 'session_changed'
            end
            local saved=publish_entry(lfs,dir,entry,account)
            if not saved or not publish_ref(lfs,dir,entry) or not can_publish() then
                return nil,live() and 'storage' or 'session_changed'
            end
            save_presence(settings,account,book.book_id,entry,can_publish)
            pcall(save_raw,lfs,dir,entry,prepared.source_raw,lease,can_publish)
            return published_copy(path,false,saved,entry,identity_member.file_id)
        end
    end
    return nil,'storage'
    end)
    if lease and not capacity then lease:release() end
    if not ok then return nil,live() and 'storage' or 'session_changed' end
    return first,second
end
return M

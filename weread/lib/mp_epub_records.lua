-- Independent EPUB identity without changing any member or its compressed data.
-- A private extra field in the second local ZIP header changes the first hash
-- sample. The first, stored mimetype header remains free of extra fields.
local bit=require('bit')
local M={MAX_ARCHIVE=72*1024*1024,MAX_CENTRAL=4*1024*1024,MAX_ENTRIES=4096,
    MAX_MEMBER=64*1024*1024,MAX_EXPANDED=128*1024*1024,EXTRA_ID=0x5752}
local MAGIC='weread-mp-epub-v1\n'
local MIME='application/epub+zip'
local function fail() error('mp_epub_records/unavailable',0) end
local function integer(n,max) return type(n)=='number' and n>=0 and n%1==0 and n<=max end
local function u16(raw,at)
    local a,b=raw:byte(at,at+1);if not b then fail() end;return a+b*256
end
local function u32(raw,at) return u16(raw,at)+u16(raw,at+2)*65536 end
local function p16(n) if not integer(n,65535) then fail() end;return string.char(n%256,math.floor(n/256)) end
local function p32(n) if not integer(n,4294967294) then fail() end;return p16(n%65536)..p16(math.floor(n/65536)) end
local function key_ok(key) return type(key)=='string' and #key==64 and key:match('^[a-f0-9]+$') end
local function nonce_ok(n) return type(n)=='string' and #n==16 and n:match('^[a-f0-9]+$') end
local function identity(key,nonce)
    if not key_ok(key) or not nonce_ok(nonce) then fail() end
    return MAGIC..key..'\n'..nonce..'\n'
end
local function decode(raw,key)
    local saved,nonce=raw:match('^weread%-mp%-epub%-v1\n([a-f0-9]+)\n([a-f0-9]+)\n$')
    return saved==key and key_ok(saved) and nonce_ok(nonce) and nonce or nil
end
local function name_ok(name)
    if type(name)~='string' or name=='' or #name>1024 or name:find('[%z%c\\:]')
        or name:sub(1,1)=='/' or name:find('//',1,true) then return false end
    for part in name:gmatch('[^/]+') do if part=='.' or part=='..' then return false end end
    return true
end
local function extras(raw,key)
    local at,kept,nonce=1,{}
    while at<=#raw do
        local kind,size=u16(raw,at),u16(raw,at+2);local finish=at+3+size
        if finish>#raw or kind==1 then fail() end -- ZIP64 is outside this bounded format.
        if kind==M.EXTRA_ID then
            if nonce then fail() end;nonce=decode(raw:sub(at+4,finish),key);if not nonce then fail() end
        else kept[#kept+1]=raw:sub(at,finish) end
        at=finish+1
    end
    return table.concat(kept),nonce
end
local function local_header(read,offset)
    local raw=read(offset,30);if raw:sub(1,4)~='PK\3\4' then fail() end
    local flags,method=u16(raw,7),u16(raw,9)
    if bit.band(flags,bit.bnot(0x80e))~=0 or method~=0 and method~=8 then fail() end
    local size,extra=u16(raw,27),u16(raw,29)
    local name=read(offset+30,size);if not name_ok(name) then fail() end
    return {offset=offset,flags=flags,method=method,name=name,extra=read(offset+30+size,extra),
        data=offset+30+size+extra,crc=u32(raw,15),compressed=u32(raw,19),size=u32(raw,23)}
end
local function descriptor(read,at,entry)
    local raw=read(at,4);local tagged=raw=='PK\7\8';local length=tagged and 16 or 12
    raw=read(at,length);local start=tagged and 5 or 1
    if u32(raw,start)~=entry.crc or u32(raw,start+4)~=entry.compressed or u32(raw,start+8)~=entry.size then fail() end
    return length
end
-- Fast managed-file check, only for copies created by this module. A full ZIP
-- and CRC scan is mandatory before creating a copy; this is not that scan.
function M.header(raw,key,expected_nonce)
    local ok,nonce=pcall(function()
        if type(raw)~='string' or not key_ok(key) then fail() end
        local function read(at,n) local value=raw:sub(at+1,at+n);if #value~=n then fail() end;return value end
        local first=local_header(read,0)
        if first.name~='mimetype' or first.method~=0 or #first.extra~=0 or read(first.data,20)~=MIME then fail() end
        local at=first.data+20
        if bit.band(first.flags,8)~=0 then
            local tagged=read(at,4)=='PK\7\8';at=at+(tagged and 16 or 12)
        elseif first.compressed~=20 or first.size~=20 then fail() end
        local head=read(at,30);if head:sub(1,4)~='PK\3\4' then fail() end
        local from=at+30+u16(head,27);local size=u16(head,29)
        local tag=read(from,4);local bytes=u16(tag,3)
        if u16(tag,1)~=M.EXTRA_ID or bytes+4>size or from+4+bytes>1024 then fail() end
        local found=decode(read(from+4,bytes),key)
        if not found or expected_nonce and found~=expected_nonce then fail() end
        return found
    end)
    return ok and nonce or nil
end
-- reader(offset, count) must return exactly count bytes from a bounded source.
-- Offsets and patch ranges are zero-based. Never extract entries to disk.
function M.plan(read,size,key,nonce)
    if not integer(size,M.MAX_ARCHIVE) or size<22 then fail() end
    local marker=identity(key,nonce)
    local length=math.min(size,65557);local tail=read(size-length,length);local found
    for at=#tail-21,1,-1 do
        if tail:sub(at,at+3)=='PK\5\6' and at+21+u16(tail,at+20)==#tail then found=at;break end
    end
    if not found then fail() end
    local end_at=size-length+found-1;local eocd=tail:sub(found)
    local count,central_size,central=u16(eocd,11),u32(eocd,13),u32(eocd,17)
    if u16(eocd,5)~=0 or u16(eocd,7)~=0 or u16(eocd,9)~=count or count<2 or count>M.MAX_ENTRIES
        or central_size>M.MAX_CENTRAL or central+central_size~=end_at then fail() end
    local raw=read(central,central_size);local entries,seen,total,at={}, {},0,1
    for _i=1,count do
        if raw:sub(at,at+3)~='PK\1\2' then fail() end
        local names,extra,comment=u16(raw,at+28),u16(raw,at+30),u16(raw,at+32)
        local finish=at+45+names+extra+comment;if finish>#raw or u16(raw,at+34)~=0 then fail() end
        local entry={name=raw:sub(at+46,at+45+names),flags=u16(raw,at+8),method=u16(raw,at+10),
            crc=u32(raw,at+16),compressed=u32(raw,at+20),size=u32(raw,at+24),offset=u32(raw,at+42),
            central_offset=central+at+41}
        if not name_ok(entry.name) or seen[entry.name] or entry.size>M.MAX_MEMBER or entry.compressed>M.MAX_ARCHIVE
            or entry.offset>=central or bit.band(entry.flags,bit.bnot(0x80e))~=0 or entry.method~=0 and entry.method~=8 then fail() end
        extras(raw:sub(at+46+names,at+45+names+extra),key)
        total=total+entry.size;if total>M.MAX_EXPANDED then fail() end
        seen[entry.name]=entry;entries[#entries+1]=entry;at=finish+1
    end
    if at~=#raw+1 or not seen.mimetype or not seen['META-INF/container.xml'] then fail() end
    table.sort(entries,function(a,b) return a.offset<b.offset end)
    local next_at=0
    for _i,entry in ipairs(entries) do
        if entry.offset~=next_at then fail() end
        local head=local_header(read,entry.offset)
        if head.name~=entry.name or head.flags~=entry.flags or head.method~=entry.method then fail() end
        if bit.band(entry.flags,8)==0 and (head.crc~=entry.crc or head.compressed~=entry.compressed or head.size~=entry.size) then fail() end
        next_at=head.data+entry.compressed
        if next_at>central then fail() end
        if bit.band(entry.flags,8)~=0 then next_at=next_at+descriptor(read,next_at,entry) end
        entry.head=head
    end
    local first,second=entries[1],entries[2]
    if next_at~=central or first.name~='mimetype' or first.method~=0 or first.size~=20 or first.compressed~=20
        or #first.head.extra~=0 or read(first.head.data,20)~=MIME then fail() end
    local old=second.head.extra;local kept=extras(old,key)
    local added=p16(M.EXTRA_ID)..p16(#marker)..marker..kept
    local from=second.head.data-#old;local delta=#added-#old
    if #added>65535 or from+4+#marker>1024 or size+delta>M.MAX_ARCHIVE then fail() end
    local patches={{offset=second.offset+28,remove=2,data=p16(#added)},
        {offset=from,remove=#old,data=added},{offset=end_at+16,remove=4,data=p32(central+delta)}}
    for _i,entry in ipairs(entries) do
        if entry.offset>=from then patches[#patches+1]={offset=entry.central_offset,remove=4,data=p32(entry.offset+delta)} end
    end
    table.sort(patches,function(a,b) return a.offset<b.offset end)
    return {size=size,bytes=size+delta,entries=entries,expanded=total,patches=patches}
end
function M.apply(read,write,plan)
    local at,written=0,0
    local function emit(raw) if not write(raw) then fail() end;written=written+#raw end
    for _i,patch in ipairs(plan.patches) do
        if patch.offset<at then fail() end
        while at<patch.offset do local count=math.min(65536,patch.offset-at);emit(read(at,count));at=at+count end
        emit(patch.data);at=at+patch.remove
    end
    while at<plan.size do local count=math.min(65536,plan.size-at);emit(read(at,count));at=at+count end
    if written~=plan.bytes then fail() end
    return written
end
local function same(a,b)
    return a and b and a.mode=='file' and b.mode=='file' and a.dev==b.dev and a.ino==b.ino
        and a.size==b.size and a.modification==b.modification
end
local function validate(path,plan)
    local ffi=require('ffi');require('ffi/libarchive_h')
    ffi.cdef[[int archive_read_support_format_zip_seekable(struct archive *);
        const char *archive_entry_symlink(struct archive_entry *);
        const char *archive_entry_hardlink(struct archive_entry *);]]
    local lib=ffi.loadlib('archive','13');local archive,entry,closed
    local ok=pcall(function()
        archive,entry=lib.archive_read_new(),lib.archive_entry_new()
        if archive==nil or entry==nil or lib.archive_read_support_format_zip_seekable(archive)~=lib.ARCHIVE_OK
            or lib.archive_read_open_filename(archive,path,65536)~=lib.ARCHIVE_OK then fail() end
        local expected={};for _i,row in ipairs(plan.entries) do expected[row.name]=row end
        local seen,count={},0;local buffer=ffi.new('char[65536]')
        while true do
            local status=lib.archive_read_next_header2(archive,entry)
            if status==lib.ARCHIVE_EOF then break end
            if status~=lib.ARCHIVE_OK then fail() end
            local pointer=lib.archive_entry_pathname(entry);if pointer==nil then fail() end
            local name=ffi.string(pointer);local row=expected[name];local kind=lib.archive_entry_filetype(entry)
            if not row or seen[name] or tonumber(lib.archive_entry_size(entry))~=row.size
                or lib.archive_entry_symlink(entry)~=nil or lib.archive_entry_hardlink(entry)~=nil
                or kind~=lib.AE_IFREG and kind~=lib.AE_IFDIR or kind==lib.AE_IFDIR and row.size~=0 then fail() end
            local bytes=0
            while true do
                local n=tonumber(lib.archive_read_data(archive,buffer,65536));if not n or n<0 then fail() end
                if n==0 then break end;bytes=bytes+n;if bytes>row.size then fail() end
            end
            if bytes~=row.size then fail() end;seen[name]=true;count=count+1
        end
        if count~=#plan.entries or lib.archive_read_close(archive)~=lib.ARCHIVE_OK then fail() end
        closed=true
    end)
    if archive~=nil then if not closed then pcall(lib.archive_read_close,archive) end;pcall(lib.archive_free,archive) end
    if entry~=nil then pcall(lib.archive_entry_free,entry) end
    if not ok then fail() end
end
local function digest(read,size)
    local hash=require('ffi/sha2').sha256();local at=0
    while at<size do local n=math.min(65536,size-at);hash(read(at,n));at=at+n end
    return hash()
end
local function source(path,expected,callback)
    if type(path)~='string' or path=='' or #path>4096 or path:find('[%z%c]') then fail() end
    local fs=require('libs/libkoreader-lfs')
    local info=fs.symlinkattributes(path)
    if not same(expected,info) or not integer(info.size,M.MAX_ARCHIVE) or info.size<22 then fail() end
    local file=io.open(path,'rb');if not file then fail() end
    local ok,result=pcall(function()
        local function read(at,n)
            if not integer(at,info.size) or not integer(n,info.size-at) or not file:seek('set',at) then fail() end
            if n==0 then return '' end
            local raw=file:read(n);if not raw or #raw~=n then fail() end;return raw
        end
        local value=callback(read,info.size)
        if not same(info,fs.symlinkattributes(path)) then fail() end
        return value
    end)
    file:close();if not ok then fail() end;return result
end
function M.inspect(path,info,key)
    return source(path,info,function(read,size)
        local plan=M.plan(read,size,key,string.rep('0',16));validate(path,plan)
        return {source_sha256=digest(read,size),entries=#plan.entries,expanded=plan.expanded}
    end)
end
function M.write(input,output,nonce,sha256)
    return source(input.path,input.info,function(read,size)
        local plan=M.plan(read,size,input.key,nonce);validate(input.path,plan)
        if digest(read,size)~=sha256 then fail() end
        M.apply(read,function(raw) return output:write(raw) end,plan)
        if digest(read,size)~=sha256 or not output:sync() then fail() end
        return {ok=true,bytes=plan.bytes,images=0,image_bytes=0}
    end)
end
return M

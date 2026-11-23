-- Conservative local cleanup for isolated E-Ink chapter copies. No network.
-- A durable per-copy marker permits an interrupted deletion to be resumed
-- without ever guessing which remaining files belong to that deletion.
local Cache=require('weread.lib.native_direct_cache')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.native_position_protocol')
local Protect=require('weread.lib.native_direct_protection')
local Lease=require('weread.lib.file_lease')
local M={}

local function fs() return require('libs/libkoreader-lfs') end
local function hash(v,n) return type(v)=='string' and #v==n and v:match('^[a-f0-9]+$')~=nil end
local function id(v) return type(v)=='string' and Protocol.id(v)==v end
local function name(key,copy) return key..(copy==0 and '' or '-'..tostring(copy)) end
local function epub(book,chapter) return 'wr-chapter-'..Crypto.sha256_hex(book..'\0'..chapter)..'.epub' end
local function same(a,b)
    return a and b and a.mode==b.mode and a.dev==b.dev and a.ino==b.ino
        and (a.mode=='directory' or a.size==b.size and a.modification==b.modification)
end
local function fingerprint(a)
    if not a or a.mode~='file' or type(a.dev)~='number' or type(a.ino)~='number'
        or type(a.size)~='number' or type(a.modification)~='number' then return nil end
    return table.concat({tostring(a.dev),tostring(a.ino),tostring(a.size),tostring(a.modification)},':')
end
local function payload(codec,record)
    local raw=codec:json_encode(record)
    if type(raw)~='string' or #raw>12000 then return nil end
    return raw..'\n'..Crypto.sha256_hex(raw)..'\n'
end
local function valid(record,vid,book,folder)
    if type(record)~='table' or record.schema~=1 or record.owner~=Crypto.sha256_hex('native-direct-account\0'..vid)
        or record.book~=book or not id(record.chapter) or not hash(record.key,64)
        or not Protocol.integer(record.copy,0,Cache.MAX_COPIES-1) or folder~=name(record.key,record.copy)
        or not hash(record.file_id,64) or not hash(record.md5,32) or type(record.files)~='table' then return false end
    local allowed={schema=true,owner=true,book=true,chapter=true,key=true,copy=true,file_id=true,md5=true,files=true}
    for key in pairs(record) do if not allowed[key] then return false end end
    local expected=epub(book,record.chapter)
    local paths={['entry.txt']=true,['receipt.txt']=true,['catalog.txt']=true,[expected]=true}
    for key,value in pairs(record.files) do
        if not paths[key] or type(value)~='string' or #value>128
            or not value:match('^[%d%.eE+%-]+:[%d%.eE+%-]+:[%d%.eE+%-]+:[%d%.eE+%-]+$') then return false end
    end
    return record.files['entry.txt']~=nil and record.files['receipt.txt']~=nil and record.files[expected]~=nil
end
local function marker(codec,dir,vid,book,folder)
    local token=Lease.open(dir..'/'..Cache.RETIRING)
    if not token then return nil end
    local raw=token:read(16384);token:release()
    if not raw then return nil end
    local body,digest=raw:match('^(.*)\n([a-f0-9]+)\n$')
    if not body or not hash(digest,64) or Crypto.sha256_hex(body)~=digest then return nil end
    local ok,record=pcall(codec.json_decode,codec,body)
    return ok and valid(record,vid,book,folder) and record or nil
end
local function entries(dir,allowed,partial)
    local found={}
    for item in fs().dir(dir) do
        if item~='.' and item~='..' and item~=Cache.RETIRING then
            if not allowed[item] or found[item] then return nil end
            local info=fs().symlinkattributes(dir..'/'..item)
            if not info or info.mode~='file' or fingerprint(info)~=allowed[item] then return nil end
            found[item]=true
        end
    end
    if not partial then for item in pairs(allowed) do if not found[item] then return nil end end end
    return found
end
local function snapshot(dir,book,chapter)
    local permitted={['entry.txt']=true,['receipt.txt']=true,['catalog.txt']=true,[epub(book,chapter)]=true}
    local result={}
    for item in fs().dir(dir) do
        if item~='.' and item~='..' then
            if not permitted[item] then return nil end
            local value=fingerprint(fs().symlinkattributes(dir..'/'..item))
            if not value then return nil end
            result[item]=value
        end
    end
    return result
end
local function bytes_remaining(dir,files,partial)
    local total=0
    for item,expected in pairs(files) do
        local attr,_,errno=fs().symlinkattributes(dir..'/'..item)
        if attr then
            if fingerprint(attr)~=expected then return nil end
            total=total+attr.size
        elseif not partial or errno~=2 then return nil end
    end
    return total
end
local function mark_references(settings,owner,book)
    local path=settings.data_dir..'/library-'..owner..'.db'
    local parent=fs().symlinkattributes(settings.data_dir)
    if not parent or parent.mode~='directory' then return nil end
    local info,_,errno=fs().symlinkattributes(path)
    if not info then
        if errno~=2 then return nil end
        for _,suffix in ipairs({'-wal','-shm','-journal'}) do
            local journal,_,why=fs().symlinkattributes(path..suffix)
            if journal or why~=2 then return nil end
        end
        return {files={},unverified=false}
    end
    if info.mode~='file' then return nil end
    local opened,db=pcall(function() return require('lua-ljsqlite3/init').open(path,'ro') end)
    if not opened or not db then return nil end
    local function query(sql,arg)
        local stmt=db:prepare(sql)
        local ok,rows=pcall(function()
            if arg then stmt:bind(arg) end
            local result={}
            while true do local row=stmt:step();if not row then break end;result[#result+1]=row end
            return result
        end)
        stmt:close();if not ok then error('mark_source_unavailable') end
        return rows
    end
    local ok,result=pcall(function()
        db:exec('PRAGMA busy_timeout=200')
        local value={files={},unverified=false}
        for _,item in ipairs({
            {name='native_direct_mark_source',sql='SELECT file_id FROM native_direct_mark_source WHERE book_id=? LIMIT 129',max=128},
            {name='native_direct_offline_pending',sql='SELECT file_id FROM native_direct_offline_pending WHERE book_id=? LIMIT 257',max=256},
        }) do
            local schema=query('SELECT type FROM sqlite_master WHERE name=? COLLATE NOCASE',item.name)
            if #schema>0 then
                assert(#schema==1 and schema[1][1]=='table')
                local rows=query(item.sql,book);assert(#rows<=item.max)
                for _,row in ipairs(rows) do
                    if hash(row[1],64) then value.files[row[1]]=true else value.unverified=true end
                end
            end
        end
        return value
    end)
    pcall(db.close,db)
    local after=fs().symlinkattributes(path);local now=fs().symlinkattributes(settings.data_dir)
    if not ok or not after or after.mode~='file' or after.dev~=info.dev or after.ino~=info.ino
        or not same(parent,now) then return nil end
    return result
end
local function reading_files_valid(settings,book,owner,codec)
    if type(settings.get_book_indexes)~='function' then return true end
    local indexes=settings:get_book_indexes()
    if type(indexes)~='table' then return false end
    local index=indexes[book]
    if index~=nil and type(index)~='table' then return false end
    local root=require('weread.lib.content').book_resolved_dir(settings,book,index or {})
    if type(root)~='string' or root=='' or root:find('[%z%c]') then return false end
    root=root:gsub('/+$','')
    local function directory(path)
        local attr,_,errno=fs().symlinkattributes(path)
        if not attr then return errno==2 and 'missing' or false end
        return attr.mode=='directory' and 'present' or false
    end
    local root_state=directory(root)
    if not root_state then return false end
    if root_state=='missing' then return index==nil end
    if index==nil then return false end
    local accounts=root..'/.weread-accounts'
    local accounts_state=directory(accounts)
    if not accounts_state then return false end
    if accounts_state=='present' and not directory(accounts..'/'..owner) then return false end
    local paths={root..'/metadata.json',root..'/reading_state.json'}
    if accounts_state=='present' then
        paths[#paths+1]=accounts..'/legacy_metadata.json'
        paths[#paths+1]=accounts..'/'..owner..'/reading_state.json'
    end
    for _,path in ipairs(paths) do
        local before,_,errno=fs().symlinkattributes(path)
        if not before then
            if errno~=2 then return false end
        else
            if before.mode~='file' or before.size<1 or before.size>2*1024*1024 then return false end
            local file=io.open(path,'rb');if not file then return false end
            local raw,read_error=file:read(2*1024*1024+1);local closed=file:close()
            local ok,value=pcall(codec.json_decode,codec,raw)
            if read_error or not closed or type(raw)~='string' or #raw~=before.size or not same(before,fs().symlinkattributes(path))
                or not ok or type(value)~='table' then return false end
        end
    end
    return true
end
local function references(settings,owner,book,vid,codec)
    local refs=require('weread.lib.offline_time_store'):new(settings.data_dir):source_references(owner,book)
    if not refs then return nil end
    local marks=mark_references(settings,owner,book)
    if not marks then return nil end
    for key in pairs(marks.files) do refs.files[key]=true end
    if marks.unverified then refs.unverified=true end
    if not reading_files_valid(settings,book,owner,codec) then refs.unverified=true;return refs end
    local saved
    if type(settings.get_book)=='function' then
        saved=settings:get_book(book)
        if not saved and type(settings.get_book_indexes)=='function' then
            local indexes=settings:get_book_indexes()
            if not indexes or indexes[book] then refs.unverified=true end
        end
    elseif type(settings.get)=='function' then
        local books=settings:get('books',{})
        if type(books)~='table' then refs.unverified=true else saved=books[book] end
    else refs.unverified=true end
    if saved~=nil and type(saved)~='table' then refs.unverified=true;return refs end
    if saved and (saved.book_id~=nil and tostring(saved.book_id)~=book
        or saved.bookId~=nil and tostring(saved.bookId)~=book
        or saved._library_account_key~=nil and saved._library_account_key~=owner) then
        refs.unverified=true;return refs
    end
    local pointer=saved and saved.native_home_resume
    if pointer and pointer~=false then
        local entry=type(pointer)=='table' and pointer.entry
        if not Cache.valid_entry(entry,book,vid) or not hash(entry.file_id,64) then refs.unverified=true
        else refs.files[entry.file_id]=true end
    end
    local claims=saved and saved.native_location_claims
    if claims and claims~=false then
        if type(claims)~='table' then refs.unverified=true
        else
            local count=0
            for key,value in pairs(claims) do
                count=count+1
                if count>128 or not hash(key,64) or type(value)~='table' or value.book_id~=book
                    or value.owner~=owner or value.path_hash~=key or not hash(value.file_id,64) then refs.unverified=true
                else refs.files[value.file_id]=true end
            end
        end
    end
    -- Other account-local checkpoints can also carry a source file identity.
    -- Keep every referenced source, even when it belongs to an older flow.
    local seen,count={},0
    local function visit(value,depth)
        if type(value)~='table' then return end
        if seen[value] or depth>8 then refs.unverified=true;return end
        seen[value]=true
        for key,part in pairs(value) do
            count=count+1
            if count>2048 then refs.unverified=true;return end
            if key=='file_id' then
                if hash(part,64) then refs.files[part]=true else refs.unverified=true end
            elseif type(part)=='table' then visit(part,depth+1) end
            if refs.unverified then return end
        end
        seen[value]=nil
    end
    if saved then
        for _,field in ipairs({'last_local_position','pending_upload_position','unindexed_resume',
            'cb_cloud_view_resume','source_dispatch'}) do visit(saved[field],1) end
    end
    return refs
end
local function signature(record)
    local fields={record.owner,record.book,record.chapter,record.key,tostring(record.copy),record.file_id,record.md5}
    local names={};for item in pairs(record.files) do names[#names+1]=item end;table.sort(names)
    for _,item in ipairs(names) do fields[#fields+1]=item;fields[#fields+1]=record.files[item] end
    return Crypto.sha256_hex(table.concat(fields,'\0'))
end

-- Caller holds the book lease while constructing and acting on the snapshot.
function M.scan(settings,vid,book,owner,codec,current,lease)
    if not id(vid) or not id(book) or owner~=require('weread.lib.native_position_contract').account_key(vid)
        or type(current)~='function' or not current() or not lease or not lease:owns() then return nil,'changed' end
    local root=Cache.book_directory(settings,vid,book);local root_info=root and fs().symlinkattributes(root)
    if not root_info or root_info.mode~='directory' then return nil,'changed' end
    local refs=references(settings,owner,book,vid,codec)
    if not refs then return nil,'storage' end
    local rows=Cache.list(settings,vid,book,current)
    if not rows then return nil,'changed' end
    local plan={root=root,root_info=root_info,items={},protected=0,bytes=0,vid=vid,book=book,owner=owner}
    local known={}
    for _,entry in ipairs(rows) do
        if not current() or not lease:owns() then return nil,'changed' end
        local folder=name(entry.key,entry.copy);known[folder]=true
        local dir=root..'/'..folder;local info=fs().symlinkattributes(dir)
        local opened=Cache.open(settings,vid,book,entry,current)
        local clear,md5
        if opened then local value,_,finger=Protect.no_sidecars(opened.path);clear,md5=value,finger end
        local files=opened and snapshot(dir,book,entry.chapter_uid)
        local record=opened and {schema=1,owner=entry.owner,book=book,chapter=entry.chapter_uid,key=entry.key,
            copy=entry.copy,file_id=opened.file_id,md5=md5,files=files}
        if info and info.mode=='directory' and record and valid(record,vid,book,folder) and clear==true
            and not refs.unverified and not refs.files[opened.file_id] then
            plan.items[#plan.items+1]={folder=folder,info=info,record=record,staged=false}
            local bytes=bytes_remaining(dir,files,false)
            if not bytes then return nil,'changed' end
            plan.bytes=plan.bytes+bytes
        else plan.protected=plan.protected+1 end
    end
    local count=0
    for folder in fs().dir(root) do
        if folder~='.' and folder~='..' and folder~='.native-operation' then
            count=count+1;if count>Cache.MAX_ENTRIES or not current() or not lease:owns() then return nil,'changed' end
            if not known[folder] then
                local dir=root..'/'..folder;local info=fs().symlinkattributes(dir)
                local record=info and info.mode=='directory' and marker(codec,dir,vid,book,folder)
                local path=record and dir..'/'..epub(book,record.chapter)
                local clear=path and Protect.no_sidecars(path,{allow_missing=true,fingerprint=record.md5})
                local present=record and entries(dir,record.files,true)
                if record and present and clear==true and not refs.unverified and not refs.files[record.file_id] then
                    plan.items[#plan.items+1]={folder=folder,info=info,record=record,staged=true}
                    local bytes=bytes_remaining(dir,record.files,true)
                    if not bytes then return nil,'changed' end
                    plan.bytes=plan.bytes+bytes
                else plan.protected=plan.protected+1 end
            end
        end
    end
    table.sort(plan.items,function(a,b) return a.folder<b.folder end)
    if not same(root_info,fs().symlinkattributes(root)) then return nil,'changed' end
    return plan
end

function M.same_plan(a,b)
    if not a or not b or a.root~=b.root or a.vid~=b.vid or a.book~=b.book or a.owner~=b.owner
        or a.protected~=b.protected or #a.items~=#b.items or not same(a.root_info,b.root_info) then return false end
    for i,item in ipairs(a.items) do
        local other=b.items[i]
        if item.folder~=other.folder or item.staged~=other.staged or not same(item.info,other.info)
            or signature(item.record)~=signature(other.record) then return false end
    end
    return true
end

-- One copy per step. The caller rechecks account, journals and reader state
-- before each step and keeps the exclusive book lease until it finishes.
function M.step(settings,codec,plan,lease,index,current)
    local item=plan.items[index];if not item then return true,'done' end
    if not current() or not lease:owns() or Cache.book_directory(settings,plan.vid,plan.book)~=plan.root
        or not same(plan.root_info,fs().symlinkattributes(plan.root)) then return false,'changed' end
    local refs=references(settings,plan.owner,plan.book,plan.vid,codec)
    if not refs or refs.unverified or refs.files[item.record.file_id] then return false,'changed' end
    local dir=plan.root..'/'..item.folder;local path=dir..'/'..epub(plan.book,item.record.chapter)
    if not same(item.info,fs().symlinkattributes(dir))
        or Protect.no_sidecars(path,{allow_missing=item.staged,fingerprint=item.record.md5})~=true
        or not entries(dir,item.record.files,item.staged) then return false,'changed' end
    if not item.staged then
        local raw=payload(codec,item.record);local token=raw and Lease.open(dir..'/'..Cache.RETIRING,{create=true,exclusive=true})
        if not token then return false,'storage' end
        local written=token:write(raw) and require('ffi/util').fsyncDirectory(dir)
        token:release()
        if not written then return false,'storage' end
    end
    local stored=marker(codec,dir,plan.vid,plan.book,item.folder)
    if not stored or signature(stored)~=signature(item.record) then return false,'changed' end
    local order={epub(plan.book,item.record.chapter),'catalog.txt','receipt.txt','entry.txt'}
    for _,file in ipairs(order) do
        if item.record.files[file] then
            local attr,_,errno=fs().symlinkattributes(dir..'/'..file)
            if attr then
                if not current() or not lease:owns() or not same(item.info,fs().symlinkattributes(dir))
                    or fingerprint(attr)~=item.record.files[file] or not os.remove(dir..'/'..file) then return false,'changed' end
            elseif errno~=2 then return false,'storage' end
        end
    end
    if not current() or not lease:owns() or not same(item.info,fs().symlinkattributes(dir)) then return false,'changed' end
    if not require('ffi/util').fsyncDirectory(dir) then return false,'storage' end
    local token=Lease.open(dir..'/'..Cache.RETIRING)
    if not token then return false,'storage' end
    local removed=token:remove();token:release()
    if not removed or not require('ffi/util').fsyncDirectory(dir) or not fs().rmdir(dir)
        or not require('ffi/util').fsyncDirectory(plan.root) then return false,'storage' end
    return true,index>=#plan.items and 'done' or 'continue'
end
return M

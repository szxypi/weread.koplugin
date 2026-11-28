-- Synthetic concurrent storage diagnosis. No account or network is used.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local mode=arg[3] or 'stress';assert(mode=='stress' or mode=='guard' or mode=='exclusive')
local kind=arg[4] or 'finish_journal'
assert(({finish_journal=true,private_journal=true,finish_queue=true,membership_queue=true})[kind])
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
require('logger').warn=function() end
pcall(ffi.cdef,'int fork(void); int waitpid(int, int *, int); void _exit(int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
local SQ3=require('lua-ljsqlite3/init');local original_open=SQ3.open
local Library=require('weread.lib.library_db')
local library=Library:new{data_dir=root,get=function(_,key,default) return key=='account' and {user_vid='900000'} or default end}
local codec={json_encode=function(_,v) return json.encode(v) end,json_decode=function(_,v) return json.decode(v) end}
local initial_path=assert(library:databasePath());local initial_db=assert(original_open(initial_path))
assert(initial_db:rowexec('PRAGMA journal_mode')=='delete');initial_db:close()
local names={finish_journal='weread.lib.finish_change_store',private_journal='weread.lib.shelf_flag_change_store',
    finish_queue='weread.lib.finish_queue_store',membership_queue='weread.lib.membership_queue_store'}
local queue=kind=='finish_queue' or kind=='membership_queue'
local Store=require(names[kind]);local store=queue and Store:new(library) or Store:new(library,codec)
if queue then
    assert(#assert(store:list())==0);assert(store:put('41',false,true))
else
    local private=kind=='private_journal'
    local Contract=require(private and 'weread.lib.shelf_flag_change_contract' or 'weread.lib.finish_change_contract')
    local metadata=Contract.make({books={{bookId='41',finishReading=0,secret=0}}},
        {book={bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=100,progress=37.5}},'41',true).metadata
    local initial=assert(store:read());local record=assert(store:begin(metadata,{vid='900000',epoch=1},initial.revision))
    assert(store:claim(record))
end
local function read(index)
    if not queue then return store:read() end
    if index%2==1 then return store:get('41') end
    local entries,reason=store:list();return entries and entries[1],reason
end
local expected=queue and 'queued' or 'pending'
local path=assert(library:databasePath())
local check=assert(original_open(path));assert(check:rowexec('PRAGMA journal_mode')=='wal');check:close()
local db=assert(original_open(path));db:exec('CREATE TABLE IF NOT EXISTS contention_test (id INTEGER PRIMARY KEY,value INTEGER)')
db:exec('INSERT OR REPLACE INTO contention_test VALUES(1,0)');db:close()
local socket=require('socket');local children={}
local memory,counters
if mode=='stress' then
    memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
end
for index=1,mode=='stress' and 3 or 0 do
    local pid=tonumber(ffi.C.fork());assert(pid>=0)
    if pid==0 then
        require('logger').warn=function() end
        while counters[0]==0 do socket.sleep(.001) end
        for _i=1,700 do
            local ok,saved=pcall(library.cacheShelf,library,{{bookId='41',title='synthetic'}},{})
            if ok and saved and counters[4]==0 then counters[index]=counters[index]+1 end
            socket.sleep(.0001)
        end
        ffi.C._exit(0)
    end
    children[#children+1]=pid
end
local event
local function error_type(value)
    local text=tostring(value):lower()
    if text:find('locked',1,true) or text:find('busy',1,true) then return 'busy' end
    if text:find('duplicate column',1,true) then return 'duplicate_column' end
    return 'other'
end
local function label(sql)
    local lower=sql:lower()
    if lower:find('journal_mode',1,true) then return 'journal_mode' end
    if lower:find('synchronous',1,true) then return 'synchronous' end
    if lower:find('alter table',1,true) then return 'alter' end
    if lower:find('create',1,true) then return 'schema' end
    if lower:find('select',1,true) then return 'select' end
    return 'other'
end
local function safe(operation,fn,...)
    local ok,a,b=pcall(fn,...)
    if not ok then event=operation..'/'..error_type(a);error('synthetic diagnostic failure',0) end
    return a,b
end
SQ3.open=function(...)
    local raw=safe('open',original_open,...)
    return {exec=function(_,sql,...)
            if mode=='guard' and sql=='PRAGMA journal_mode=WAL' then event='journal_mode/busy';error('synthetic busy',0) end
            return safe(label(sql),raw.exec,raw,sql,...)
        end,
        rowexec=function(_,sql,...) return safe(label(sql)..'_read',raw.rowexec,raw,sql,...) end,
        set_busy_timeout=function(_,value) return safe('busy_timeout',raw.set_busy_timeout,raw,value) end,
        prepare=function(_,sql)
            local stmt=safe(label(sql)..'_prepare',raw.prepare,raw,sql)
            local proxy={}
            function proxy:bind(...) safe(label(sql)..'_bind',stmt.bind,stmt,...);return self end
            function proxy:step(...) return safe(label(sql)..'_step',stmt.step,stmt,...) end
            function proxy:close() return safe(label(sql)..'_close',stmt.close,stmt) end
            return proxy
        end,
        close=function() return safe('close',raw.close,raw) end}
end
local counts={success=0,storage=0}
local blocker
if mode=='exclusive' then
    blocker=assert(original_open(path));blocker:exec('PRAGMA locking_mode=EXCLUSIVE');blocker:exec('BEGIN EXCLUSIVE')
    blocker:exec('UPDATE contention_test SET value=value+1 WHERE id=1')
end
local started=socket.gettime()
if counters then counters[0]=1 end
for index=1,mode=='stress' and 5000 or 1 do
    event=nil;local value,reason=read(index)
    if value then assert(value.phase==expected);counts.success=counts.success+1
    else assert(reason=='storage');counts.storage=counts.storage+1;local key=event or 'unknown';counts[key]=(counts[key] or 0)+1 end
end
local elapsed=socket.gettime()-started
if counters then counters[4]=1 end
SQ3.open=original_open
if blocker then blocker:exec('ROLLBACK');blocker:close() end
for _,pid in ipairs(children) do local status=ffi.new('int[1]');assert(ffi.C.waitpid(pid,status,0)==pid and status[0]==0) end
if counters then
    counts.concurrent_saves=counters[1]+counters[2]+counters[3]
    assert(counts.concurrent_saves>0,'no shelf save overlapped the journal reads')
    ffi.C.munmap(memory,4096)
end
assert(read(1).phase==expected)
print(json.encode(counts))
if mode=='guard' then assert(counts.success==1 and counts.storage==0,'WAL read needlessly attempted a mode change') end
if mode=='exclusive' then
    assert(counts.storage==1 and counts.success==0 and elapsed<.5,'locked read did not fail within its bounded wait')
end

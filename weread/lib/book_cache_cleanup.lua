-- Delete download material while retaining reading journals and native notes.
local Operation = require('weread.lib.book_operation')
local M = { MAX_ENTRIES=16384, MAX_DEPTH=24, MAX_METADATA=2*1024*1024 }
local function fs() return require('libs/libkoreader-lfs') end
local function fail(reason) error('book_cleanup/'..reason,0) end
local function same(a,b)
    return a and b and a.mode==b.mode and a.dev==b.dev and a.ino==b.ino
end
local function unchanged(a,b)
    return same(a,b) and (a.mode=='directory' or a.size==b.size and a.modification==b.modification)
end
local function codec()
    local ok,json=pcall(require,'json');return ok and json or require('rapidjson')
end
function M.retained(name, directory)
    if directory then return name:match('%.sdr$') or name:match('^%.mp%-quarantine%-') end
    if name==Operation.NAME or name=='.mp-cleanup' then return true end
    -- A book title can contain ".lua" or ".json". Its final document
    -- extension still identifies a downloaded book rather than a record.
    if name:match('%.epub$') or name:match('%.html$') or name:match('%.xhtml$') then return false end
    if name:match('%.lua') or name:match('%.json') and name~='catalog.json' and name~='articles.json' then return true end
    return false
end
local function read_metadata(root,id)
    local path=root..'/metadata.json';local info=fs().symlinkattributes(path)
    if not info or info.mode~='file' or info.size>M.MAX_METADATA then fail('unavailable') end
    local file=io.open(path,'rb');if not file then fail('unavailable') end
    local raw=file:read(M.MAX_METADATA+1);file:close()
    if not raw or #raw>M.MAX_METADATA or not unchanged(info,fs().symlinkattributes(path)) then fail('changed') end
    local ok,data=pcall(codec().decode,raw)
    if not ok or type(data)~='table' or tostring(data.book_id or data.bookId or '')~=tostring(id)
        or data.book_id and data.bookId and tostring(data.book_id)~=tostring(data.bookId) then fail('ownership') end
    local function inside(target)
        return type(target)=='string' and target:sub(1,#root+1)==root..'/' and Operation.path(target)
    end
    for _i,name in ipairs({'cached_file','cached_full_book'}) do
        local target=data[name]
        if target~=nil and not inside(target) then fail('ownership') end
    end
    if data.cached_chapters~=nil and type(data.cached_chapters)~='table'
        or data.annotation_documents~=nil and type(data.annotation_documents)~='table' then fail('ownership') end
    for _uid,target in pairs(data.cached_chapters or {}) do
        if not inside(target) then fail('ownership') end
    end
    for target in pairs(data.annotation_documents or {}) do
        if not inside(target) then fail('ownership') end
    end
    return raw,info
end
function M.scan(root,id)
    if not Operation.path(root) then fail('ownership') end
    root=root:gsub('/+$','')
    local basename=tostring(id):gsub('[^%w%._-]','_')
    if basename=='' or basename=='.' or basename=='..' or root:match('/([^/]+)$')~=basename then fail('ownership') end
    local owner=fs().symlinkattributes(root)
    if not owner or owner.mode~='directory' then fail('unavailable') end
    local metadata,meta_info=read_metadata(root,id)
    local plan={root=root,id=tostring(id),owner=owner,metadata=metadata,meta_info=meta_info,
        entries={},retained=0,files=0,bytes=0,names={},directories={[root]=owner}}
    local count=0
    local function walk(path,depth)
        if depth>M.MAX_DEPTH then fail('capacity') end
        local names={}
        for name in fs().dir(path) do
            if name~='.' and name~='..' then
                count=count+1;if count>M.MAX_ENTRIES or name:find('[%z%c]') then fail('capacity') end
                names[#names+1]=name
            end
        end
        table.sort(names);plan.names[path]=names
        for _i,name in ipairs(names) do
            local child=path..'/'..name;local info=fs().symlinkattributes(child)
            if not info or info.mode~='file' and info.mode~='directory' then fail('ownership') end
            if name:match('^%.mp%-pending%-') or name:match('^%.mp%-download%-') then fail('busy') end
            if M.retained(name,info.mode=='directory') then plan.retained=plan.retained+1
            elseif info.mode=='directory' then
                plan.directories[child]=info
                local preserved=plan.retained;walk(child,depth+1)
                -- A retained descendant keeps its parent directory too.
                -- Keep MP item gates in stable parent directories, including
                -- when a gate is first created between preview and confirmation.
                if preserved==plan.retained and child~=root..'/mp-articles' and path~=root..'/mp-articles' then
                    plan.entries[#plan.entries+1]={path=child,info=info}
                end
            else
                plan.files=plan.files+1;plan.bytes=plan.bytes+(info.size or 0)
                plan.entries[#plan.entries+1]={path=child,info=info}
            end
        end
    end
    walk(root,0)
    if not same(owner,fs().symlinkattributes(root)) then fail('changed') end
    return plan
end
function M.acquire(root,id)
    if not Operation.path(root) then return nil,'ownership' end
    root=root:gsub('/+$','')
    local lease,reason=Operation.open(root,true)
    if not lease then return nil,reason end
    local locks={lease}
    local ok=pcall(function()
        M.scan(root,id)
        local parent=root..'/mp-articles';local info=fs().symlinkattributes(parent)
        if info then
            if info.mode~='directory' then fail('ownership')
            else
                for key in fs().dir(parent) do
                    if key~='.' and key~='..' then
                        if #key~=64 or not key:match('^[a-f0-9]+$') then fail('ownership') end
                        local lock=require('weread.lib.mp_cache_cleanup').open_lock(root,key,true)
                        if not lock then fail('busy') end
                        locks[#locks+1]=lock
                    end
                end
            end
        end
    end)
    local group={locks=locks,root=root}
    function group:release() for _i=#self.locks,1,-1 do self.locks[_i]:release() end;self.locks={} end
    function group:owns()
        for _i,lock in ipairs(self.locks) do if not lock:owns() then return false end end
        return #self.locks>0
    end
    if not ok then group:release();return nil,'busy' end
    -- Item gates may have been newly created. Take the authoritative snapshot
    -- only after all writers have been excluded.
    local plan
    ok,plan=pcall(M.scan,root,id)
    if not ok then group:release();return nil,'changed' end
    return group,plan
end
function M.same_plan(left,right)
    if not left or not right or left.root~=right.root or left.id~=right.id or left.metadata~=right.metadata
        or #left.entries~=#right.entries or not same(left.owner,right.owner) then return false end
    for path,info in pairs(left.directories) do if not same(info,right.directories[path]) then return false end end
    for path in pairs(right.directories) do if not left.directories[path] then return false end end
    for i,entry in ipairs(left.entries) do
        local other=right.entries[i]
        if entry.path~=other.path or not unchanged(entry.info,other.info) then return false end
    end
    return true
end
function M.step(job,limit)
    local plan,lease=job.plan,job.lease
    if not lease:owns() or not same(plan.owner,fs().symlinkattributes(plan.root)) then return false,'changed' end
    local ok,metadata=pcall(read_metadata,plan.root,plan.id)
    if not ok or metadata~=plan.metadata then return false,'changed' end
    local stop=math.min(#plan.entries,(job.index or 1)+(limit or 32)-1)
    while (job.index or 1)<=stop do
        local index=job.index or 1;local entry=plan.entries[index]
        local parent=entry.path:match('^(.*)/[^/]+$')
        while parent and #parent>=#plan.root do
            if not same(plan.directories[parent],fs().symlinkattributes(parent)) then return false,'changed' end
            parent=parent:match('^(.*)/[^/]+$')
        end
        if not unchanged(entry.info,fs().symlinkattributes(entry.path)) then return false,'changed' end
        local removed
        if entry.info.mode=='directory' then removed=fs().rmdir(entry.path) else removed=os.remove(entry.path) end
        if not removed then return false,'remove_failed' end
        if entry.info.mode=='file' then job.files=(job.files or 0)+1;job.bytes=(job.bytes or 0)+(entry.info.size or 0) end
        job.index=index+1
    end
    return true,(job.index or 1)>#plan.entries and 'done' or 'continue'
end
return M

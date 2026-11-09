-- Explicit local cache cleanup. Retained HTML is the image reachability root.
local Versions=require('weread.lib.mp_cache_versions')
local Identity=require('weread.lib.mp_cache_identity')
local M={MAX_FILES=4096,MAX_IMAGES=256}
local function fs() return require('libs/libkoreader-lfs') end
local function same(a,b)
    return a and b and a.mode==b.mode and a.dev==b.dev and a.ino==b.ino
end
local function regular(a,b) return same(a,b) and a.size==b.size and a.modification==b.modification end
local function body_name(name)
    local nonce=name:match('^article%-([a-f0-9]+)%.html$')
    return name=='article.html' or nonce and #nonce==16
end
local function generation(name,key)
    local prefix='.weread-mp-'..key..'-assets-'
    local nonce=name:sub(1,#prefix)==prefix and name:sub(#prefix+1)
    return nonce and #nonce==16 and nonce:match('^[a-f0-9]+$')
end
local function fail(kind) error('mp_cleanup/'..kind,0) end
local function children(path,max)
    local names={}
    for name in fs().dir(path) do
        if name~='.' and name~='..' then names[#names+1]=name;if #names>max then fail('capacity') end end
    end
    table.sort(names);return names
end
local function names_equal(a,b)
    if #a~=#b then return false end
    for i=1,#a do if a[i]~=b[i] then return false end end
    return true
end
local function quarantined(parent)
    for _i,name in ipairs(children(parent,1024)) do if name:match('^%.mp%-quarantine%-') then return true end end
    return false
end
function M.open_lock(root,key,create)
    local base=Identity.path(root,key);if not base then return nil,'unavailable' end
    local parent=base:match('^(.*)/[^/]+$');local path=parent..'/.mp-cleanup'
    local owner=fs().symlinkattributes(parent)
    if not owner or owner.mode~='directory' or fs().symlinkattributes(root..'/mp-articles','mode')~='directory' then return nil,create and 'unavailable' or 'absent' end
    return require('weread.lib.file_lease').open(path,{create=create,empty=true})
end
function M.locked(root,key)
    local lock,reason=M.open_lock(root,key,false)
    if lock then lock:release();return false end
    return reason~='absent' and reason~='unsupported'
end
function M.scan(root,key,opened,lock)
    local snapshot=Versions.capture(root,key);if not snapshot then fail('unavailable') end
    local parent=snapshot.parent;local names=children(parent,Versions.MAX_ENTRIES)
    local plan={root=root,key=key,snapshot=snapshot,opened=opened,versions={},generations={},names=names,files=0,quarantined=quarantined(parent)}
    local open_parent=type(opened)=='string' and opened:sub(1,#parent+1)==parent..'/'
    for _i,name in ipairs(names) do
        local path=parent..'/'..name
        if name=='.mp-cleanup' then
            local info=fs().symlinkattributes(path)
            if not info or info.mode~='file' or info.size~=0 or lock and not same(lock,info) or not lock and M.locked(root,key) then fail('busy') end
        elseif name:match('^%.mp%-pending%-') then fail('busy')
        elseif body_name(name) then
            if not Versions.contains(root,key,path) then fail('unavailable') end
            local info=fs().symlinkattributes(path)
            local file=io.open(path,'rb');if not file then fail('unavailable') end
            local raw=file:read(4*1024*1024+1);file:close()
            if not raw or #raw>4*1024*1024 or not regular(info,fs().symlinkattributes(path)) then fail('changed') end
            if #plan.versions>=Versions.MAX_VERSIONS then fail('capacity') end
            local refs={}
            for owner,nonce in raw:gmatch('%.weread%-mp%-([a-f0-9]+)%-assets%-([a-f0-9]+)') do
                if owner==key and #nonce==16 then refs['.weread-mp-'..owner..'-assets-'..nonce]=true end
            end
            plan.versions[#plan.versions+1]={name=name,info=info,refs=refs,current=path==snapshot.path,
                opened=path==opened or type(opened)=='string' and regular(info,fs().symlinkattributes(opened)) or false}
        elseif generation(name,key) then
            local info=fs().symlinkattributes(path)
            if not info or info.mode~='directory' then fail('unavailable') end
            local items=children(path,2)
            if #items~=1 or items[1]~='images' then fail('unavailable') end
            local images=fs().symlinkattributes(path..'/images')
            if not images or images.mode~='directory' then fail('unavailable') end
            local files={};local bytes=0
            for _j,filename in ipairs(children(path..'/images',M.MAX_IMAGES)) do
                if not filename:match('^img%-%d%d%d%d%.png$') and not filename:match('^img%-%d%d%d%d%.jpg$')
                    and not filename:match('^img%-%d%d%d%d%.gif$') and not filename:match('^img%-%d%d%d%d%.webp$') then fail('unavailable') end
                local image=fs().symlinkattributes(path..'/images/'..filename)
                if not image or image.mode~='file' then fail('unavailable') end
                plan.files=plan.files+1;if plan.files>M.MAX_FILES then fail('capacity') end
                files[#files+1]={name=filename,info=image};bytes=bytes+image.size
            end
            plan.generations[#plan.generations+1]={name=name,info=info,images=images,files=files,bytes=bytes,protected=open_parent or plan.quarantined or false}
        elseif name:match('%.html$') then fail('unavailable') end
    end
    if not Versions.matches(snapshot) or not names_equal(names,children(parent,Versions.MAX_ENTRIES)) then fail('changed') end
    return plan
end
function M.targets(plan,selected)
    local body
    if selected then
        for _i,item in ipairs(plan.versions) do if item.name==selected then body=item end end
        if not body or body.current or body.opened then fail('protected') end
    end
    local reachable={}
    for _i,item in ipairs(plan.versions) do
        if item~=body then for name in pairs(item.refs) do reachable[name]=true end end
    end
    local targets,bytes={},body and body.info.size or 0
    for _i,item in ipairs(plan.generations) do
        if not item.protected and not reachable[item.name] then targets[#targets+1]=item;bytes=bytes+item.bytes end
    end
    return {body=body,generations=targets,bytes=bytes}
end
local function array(value,max)
    if type(value)~='table' or #value>max then fail('invalid') end
    local n=0;for key in pairs(value) do if type(key)~='number' or key%1~=0 or key<1 or key>#value then fail('invalid') end;n=n+1 end
    if n~=#value then fail('invalid') end
    return value
end
local function stat(value,mode)
    if type(value)~='table' or value.mode~=mode then fail('invalid') end
    local copy={mode=mode}
    for _i,key in ipairs({'dev','ino','size','modification'}) do
        local n=value[key];if type(n)~='number' or n~=n or n==math.huge or n==-math.huge then fail('invalid') end;copy[key]=n
    end
    if copy.size<0 then fail('invalid') end
    return copy
end
-- Pipe results contain only strict relative names and bounded stat/boolean data.
-- Rebuild path authority and the active snapshot in the parent, never from JSON.
function M.check(value,root,key,opened)
    if type(value)~='table' or value.root~=root or value.key~=key or type(value.snapshot)~='table' then fail('invalid') end
    local snapshot=Versions.capture(root,key)
    if not snapshot or value.snapshot.selector.raw~=snapshot.selector.raw or not regular(value.snapshot.info,snapshot.info)
        or not same(value.snapshot.parent_info,snapshot.parent_info) then fail('changed') end
    local plan={root=root,key=key,snapshot=snapshot,opened=opened,versions={},generations={},quarantined=quarantined(snapshot.parent)}
    local seen,total={},0
    for _i,item in ipairs(array(value.versions,Versions.MAX_VERSIONS)) do
        if type(item)~='table' or type(item.name)~='string' or not body_name(item.name) or seen[item.name] then fail('invalid') end
        seen[item.name]=true
        local info=stat(item.info,'file');local refs={};local count=0
        if type(item.refs)~='table' then fail('invalid') end
        for name,used in pairs(item.refs) do
            count=count+1;if type(name)~='string' or not generation(name,key) or used~=true or count>Versions.MAX_ENTRIES then fail('invalid') end
            refs[name]=true
        end
        local path=snapshot.parent..'/'..item.name
        plan.versions[#plan.versions+1]={name=item.name,info=info,refs=refs,current=path==snapshot.path,
            opened=path==opened or type(opened)=='string' and regular(info,fs().symlinkattributes(opened)) or false}
    end
    if not seen[snapshot.path:match('[^/]+$')] then fail('invalid') end
    seen={}
    for _i,item in ipairs(array(value.generations,Versions.MAX_ENTRIES)) do
        if type(item)~='table' or type(item.name)~='string' or not generation(item.name,key) or seen[item.name] then fail('invalid') end
        seen[item.name]=true
        local files,bytes,seen_files={},0,{}
        for _j,file in ipairs(array(item.files,M.MAX_IMAGES)) do
            if type(file)~='table' or type(file.name)~='string' or not file.name:match('^img%-%d%d%d%d%.[a-z]+$')
                or not ({png=true,jpg=true,gif=true,webp=true})[file.name:match('%.([a-z]+)$')] then fail('invalid') end
            if seen_files[file.name] then fail('invalid') end;seen_files[file.name]=true
            local info=stat(file.info,'file');total=total+1;if total>M.MAX_FILES then fail('capacity') end
            files[#files+1]={name=file.name,info=info};bytes=bytes+info.size
        end
        plan.generations[#plan.generations+1]={name=item.name,info=stat(item.info,'directory'),images=stat(item.images,'directory'),
            files=files,bytes=bytes,protected=plan.quarantined or type(opened)=='string' and opened:sub(1,#snapshot.parent+1)==snapshot.parent..'/' or false}
    end
    return plan
end
-- Only cooperative KOReader jobs are serialized. Unknown locks/pending work are
-- left intact. No age-based PID guessing or recursive deletion is performed.
function M.acquire(root,key)
    local snapshot=Versions.capture(root,key);if not snapshot then return nil end
    return M.open_lock(root,key,true)
end
function M.begin(plan,selected,lock,prepared)
    if not lock or not lock.fd or not same(lock.info,fs().symlinkattributes(lock.path)) then fail('changed') end
    local fresh=prepared or M.scan(plan.root,plan.key,plan.opened,lock.info)
    if fresh.snapshot.selector.raw~=plan.snapshot.selector.raw or not Versions.same(fresh.snapshot.selector.info,plan.snapshot.selector.info)
        or not same(fresh.snapshot.parent_info,plan.snapshot.parent_info) or not regular(fresh.snapshot.info,plan.snapshot.info) then fail('changed') end
    local original={};for _i,item in ipairs(plan.versions) do original[item.name]=item end
    if #fresh.versions~=#plan.versions or #fresh.generations~=#plan.generations then fail('changed') end
    for _i,item in ipairs(fresh.versions) do
        if not original[item.name] or not regular(item.info,original[item.name].info) then fail('changed') end
        for name in pairs(item.refs) do if not original[item.name].refs[name] then fail('changed') end end
        for name in pairs(original[item.name].refs) do if not item.refs[name] then fail('changed') end end
    end
    local before={};for _i,item in ipairs(plan.generations) do before[item.name]=item end
    for _i,item in ipairs(fresh.generations) do
        local old=before[item.name]
        if not old or not same(old.info,item.info) or not same(old.images,item.images) or old.protected~=item.protected
            or #old.files~=#item.files then fail('changed') end
        for i,file in ipairs(item.files) do if file.name~=old.files[i].name or not regular(file.info,old.files[i].info) then fail('changed') end end
    end
    return {plan=fresh,target=M.targets(fresh,selected),lock=lock,removed_files=0,removed_bytes=0,body_done=false,generation=1,index=1}
end
local function guard(job)
    local plan=job.plan
    if not job.lock.fd or not same(job.lock.info,fs().symlinkattributes(job.lock.path)) or not Versions.matches(plan.snapshot) then return false end
    local expected={};for _i,item in ipairs(plan.versions) do
        if not (job.body_done and item==job.target.body) then
            expected[item.name]=true
            if not regular(item.info,fs().symlinkattributes(plan.snapshot.parent..'/'..item.name)) then return false end
        end
    end
    for _i,name in ipairs(children(plan.snapshot.parent,Versions.MAX_ENTRIES)) do
        if name:match('^%.mp%-pending%-') or name:match('%.html$') and not expected[name] then return false end
    end
    return true
end
function M.step(job)
    if not guard(job) then return false,'changed' end
    local parent=job.plan.snapshot.parent
    local body=job.target.body
    if not job.body_done then
        if body and not os.remove(parent..'/'..body.name) then return false,'storage' end
        job.body_done=true
        if body then job.removed_files=job.removed_files+1;job.removed_bytes=job.removed_bytes+body.info.size end
    end
    for _i=1,16 do
        local item=job.target.generations[job.generation]
        if not item then return true,'done' end
        local path=parent..'/'..item.name
        if not same(item.info,fs().symlinkattributes(path)) or not same(item.images,fs().symlinkattributes(path..'/images')) then return false,'changed' end
        local file=item.files[job.index]
        if file then
            if not regular(file.info,fs().symlinkattributes(path..'/images/'..file.name)) then return false,'changed' end
            if not os.remove(path..'/images/'..file.name) then return false,'storage' end
            job.removed_files=job.removed_files+1;job.removed_bytes=job.removed_bytes+file.info.size;job.index=job.index+1
        else
            if not fs().rmdir(path..'/images') or not fs().rmdir(path) then return false,'storage' end
            job.generation=job.generation+1;job.index=1
        end
    end
    return true,'more'
end
return M

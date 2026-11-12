-- Attempt records are local metadata, never login state or downloaded content.
local Identity=require('weread.lib.mp_cache_identity')
local Lease=require('weread.lib.file_lease')
local Versions=require('weread.lib.mp_cache_versions')
local M={MAX_RECORD=4096,MAX_FILES=1024}
local function fs() return require('libs/libkoreader-lfs') end
local function same(a,b) return Lease.same(a,b) end
local function unchanged(a,b) return not a and not b or same(a,b) and a.size==b.size and a.modification==b.modification end
local function fail() error('mp_recovery/unavailable',0) end
local function nonce(value) return type(value)=='string' and #value==16 and value:match('^[a-f0-9]+$') end
local function names(path,max)
    local result={}
    for name in fs().dir(path) do
        if name~='.' and name~='..' then result[#result+1]=name;if #result>max then fail() end end
    end
    table.sort(result);return result
end
local function regular(path)
    local info=fs().symlinkattributes(path);return info and info.mode=='file' and info
end
local function image_name(value)
    local ext=value:match('^img%-%d%d%d%d%.([a-z]+)$')
    return ext and ({png=true,jpg=true,gif=true,webp=true})[ext]
end
local function id(value) return {dev=value.dev,ino=value.ino,mode=value.mode} end
local function json()
    if M.codec then return M.codec end
    local ok,codec=pcall(require,'json');if not ok then codec=require('rapidjson') end
    return codec
end
function M.record_name(value) return '.mp-attempt-'..value..'.json' end
function M.create(stage,value)
    local path=stage.parent..'/'..M.record_name(value)
    local lease=Lease.open(path,{create=true,exclusive=true});if not lease then return nil end
    local ok,raw=pcall(function() return json().encode({schema=1,key=stage.key,nonce=value,parent=id(stage.parent_identity),
        directory=id(stage.identity),images=id(stage.images_identity),body={name=stage.output.path:match('[^/]+$'),identity=id(stage.output.identity)}}) end)
    if not ok or type(raw)~='string' or #raw>M.MAX_RECORD or not lease:write(raw) then lease:remove();lease:release();return nil end
    return lease
end
function M.parent(root,key)
    local path=Identity.path(root,key);local parent=path and path:match('^(.*)/[^/]+$')
    if not parent or fs().symlinkattributes(root..'/mp-articles','mode')~='directory' or fs().symlinkattributes(parent,'mode')~='directory' then return nil end
    return parent
end
local function missing(root,key)
    local path=Identity.path(root,key);if not path then return false end
    local container=fs().symlinkattributes(root..'/mp-articles')
    local parent=fs().symlinkattributes(path:match('^(.*)/[^/]+$'))
    if container and container.mode~='directory' or parent and parent.mode~='directory' then return false end
    return not container or not parent
end
local function layout(key,n)
    return {pending='.mp-pending-'..n,generation='.weread-mp-'..key..'-assets-'..n,
        quarantine_pending='.mp-quarantine-pending-'..n,quarantine_generation='.mp-quarantine-generation-'..n}
end
local function body_name(name)
    return name=='article.html' or Versions.name_ok(name)
end
local function payload(lease,key,n,parent_info)
    local raw=lease:read(M.MAX_RECORD);local ok,value=pcall(function() return raw and json().decode(raw) end)
    if not ok or type(value)~='table' or value.schema~=1 or value.key~=key or value.nonce~=n
        or not same(value.parent,parent_info) or type(value.directory)~='table' or value.directory.mode~='directory'
        or type(value.images)~='table' or value.images.mode~='directory' or type(value.body)~='table'
        or type(value.body.name)~='string' or not value.body.name:match('^body%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+%.html$')
        or type(value.body.identity)~='table' or value.body.identity.mode~='file' then return nil end
    return value
end
local function inspect_unchecked(parent,name,record)
    local path=parent..'/'..name;local info=fs().symlinkattributes(path)
    if not info or info.mode~='directory' or not same(info,record.directory) then return nil end
    local files,dirs,bytes={},{},0
    for _i,entry in ipairs(names(path,3)) do
        local target=path..'/'..entry
        if entry=='images' then
            local images=fs().symlinkattributes(target)
            if not same(images,record.images) then return nil end
            dirs[#dirs+1]={name='images',info=images}
            for _j,filename in ipairs(names(target,512)) do
                if not image_name(filename)
                    and not filename:match('^bitmap%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+%.html$') then return nil end
                local item=regular(target..'/'..filename);if not item then return nil end
                files[#files+1]={name='images/'..filename,info=item};bytes=bytes+item.size
            end
        elseif entry==record.body.name then
            local item=regular(target)
            if not same(item,record.body.identity) then return nil end
            files[#files+1]={name=entry,info=item};bytes=bytes+item.size
        else return nil end
    end
    return {name=name,info=info,files=files,dirs=dirs,bytes=bytes}
end
local function inspect(parent,name,record)
    local ok,value=pcall(inspect_unchecked,parent,name,record)
    return ok and value or nil
end
local function snapshot(root,key)
    local parent=M.parent(root,key);if not parent then fail() end
    local state={parent=parent,parent_info=fs().symlinkattributes(parent),entries={},bodies={},refs={},unsafe=false}
    local references=0
    local function remember(name)
        if not state.refs[name] then references=references+1;if references>1024 then fail() end;state.refs[name]=true end
    end
    for _i,name in ipairs(names(parent,1024)) do
        if name~='.mp-cleanup' then
            local info=fs().symlinkattributes(parent..'/'..name);if not info then fail() end
            state.entries[#state.entries+1]={name=name,info=info}
            if body_name(name) then
                if name:match('%.epub$') then
                    if not Versions.valid(parent..'/'..name,key) then state.unsafe=true end
                elseif info.mode~='file' or info.size>4*1024*1024 then state.unsafe=true
                else
                    local file=io.open(parent..'/'..name,'rb');if not file then fail() end
                    local raw=file:read(4*1024*1024+1);file:close()
                    if not raw or #raw>4*1024*1024 or not unchanged(info,fs().symlinkattributes(parent..'/'..name)) then fail() end
                    if not raw:sub(1,4096):find(Identity.marker(key),1,true) then state.unsafe=true end
                    for n in raw:gmatch('%.mp%-pending%-([a-f0-9]+)') do if nonce(n) then remember('.mp-pending-'..n) end end
                    for owner,n in raw:gmatch('%.weread%-mp%-([a-f0-9]+)%-assets%-([a-f0-9]+)') do
                        if owner==key and nonce(n) then remember('.weread-mp-'..owner..'-assets-'..n) end
                    end
                end
                state.bodies[#state.bodies+1]={name=name,info=info}
            elseif name:match('%.html$') or name:match('%.epub$') then state.unsafe=true end
        end
    end
    return state
end
local function inventory_same(a,b)
    if not same(a.parent_info,b.parent_info) or #a.entries~=#b.entries then return false end
    for i,item in ipairs(a.entries) do
        local other=b.entries[i]
        if item.name~=other.name or not same(item.info,other.info) or item.info.mode=='file' and not unchanged(item.info,other.info) then return false end
    end
    return true
end
local function ordinary_generation(parent,name)
    local ok,result=pcall(function()
        local path=parent..'/'..name;local entries=names(path,2)
        if #entries~=1 or entries[1]~='images' or fs().symlinkattributes(path..'/images','mode')~='directory' then return false end
        for _i,filename in ipairs(names(path..'/images',512)) do
            if not image_name(filename) or not regular(path..'/images/'..filename) then return false end
        end
        return true
    end)
    return ok and result
end
function M.scan(root,key,opened)
    if not M.parent(root,key) then
        if missing(root,key) then return {root=root,key=key,missing=true,items={}} end;fail()
    end
    local state=snapshot(root,key);local groups={}
    for _i,entry in ipairs(state.entries) do
        local n=entry.name:match('^%.mp%-attempt%-([a-f0-9]+)%.json$') or entry.name:match('^%.mp%-pending%-([a-f0-9]+)$')
            or entry.name:match('^%.mp%-quarantine%-pending%-([a-f0-9]+)$') or entry.name:match('^%.mp%-quarantine%-generation%-([a-f0-9]+)$')
        if not n then
            local prefix='.weread-mp-'..key..'-assets-'
            if entry.name:sub(1,#prefix)==prefix then n=entry.name:sub(#prefix+1) end
        end
        if nonce(n) then groups[n]=true end
    end
    local plan={root=root,key=key,state=state,items={},active=false}
    for n in pairs(groups) do
        local paths=layout(key,n);local item={nonce=n,status='unknown',bytes=0}
        local count=0
        for kind,name in pairs(paths) do
            local info=fs().symlinkattributes(state.parent..'/'..name)
            if info then count=count+1;item.kind=kind;item.name=name;item.info=info end
        end
        local record_path=state.parent..'/'..M.record_name(n)
        item.record_info=fs().symlinkattributes(record_path)
        local lease,reason=Lease.open(record_path,{})
        local record=lease and payload(lease,key,n,state.parent_info)
        if reason=='busy' then item.status='active';plan.active=true
        elseif count>1 then item.status='conflict'
        elseif count==0 then item.status=record and 'record' or 'unknown_record'
        elseif item.info.mode~='directory' then item.status='conflict'
        elseif item.kind:match('^quarantine') then
            local prefix=state.parent..'/'..item.name..'/'
            item.status=type(opened)=='string' and opened:sub(1,#prefix)==prefix and 'protected' or 'quarantine'
        else
            local referenced=state.unsafe or state.refs[item.name]
            local open_path=type(opened)=='string' and opened:sub(1,#state.parent+1)==state.parent..'/'
            local under=type(opened)=='string' and opened:sub(1,#state.parent+#item.name+2)==state.parent..'/'..item.name..'/'
            if record and same(record.body.identity,type(opened)=='string' and fs().symlinkattributes(opened)) then under=true end
            local contents=record and inspect(state.parent,item.name,record)
            if contents then
                item.contents=contents;item.bytes=contents.bytes+(item.record_info and item.record_info.size or 0)
                for _i,file in ipairs(contents.files) do
                    if same(file.info,type(opened)=='string' and fs().symlinkattributes(opened)) then under=true end
                end
            end
            if not item.record_info and item.kind=='generation' and ordinary_generation(state.parent,item.name) then item.skip=true
            elseif under or referenced and not contents or item.kind=='generation' and open_path then item.status='protected'
            elseif contents then
                if referenced then
                    local body=false;for _i,file in ipairs(contents.files) do if file.name==record.body.name then body=true end end
                    item.status=body and 'protected' or 'completed'
                else item.status='owned' end
            end
        end
        if lease then lease:release() end
        if item.status=='completed' or item.status=='record' then item.bytes=item.record_info and item.record_info.size or 0 end
        if not item.skip then plan.items[#plan.items+1]=item end
    end
    table.sort(plan.items,function(a,b) return a.nonce<b.nonce end)
    if not inventory_same(state,snapshot(root,key)) then fail() end
    return plan
end
local function array(value,max)
    if type(value)~='table' or #value>max then fail() end
    local count=0;for key in pairs(value) do if type(key)~='number' or key%1~=0 or key<1 or key>#value then fail() end;count=count+1 end
    if count~=#value then fail() end;return value
end
local function stat(value)
    if type(value)~='table' or not ({file=true,directory=true,link=true})[value.mode] then fail() end
    local result={mode=value.mode}
    for _i,key in ipairs({'dev','ino','size','modification'}) do
        local n=value[key];if type(n)~='number' or n~=n or n==math.huge or n==-math.huge then fail() end;result[key]=n
    end
    if result.size<0 then fail() end;return result
end
local function basename(value)
    return type(value)=='string' and #value>0 and #value<=255 and value~='.' and value~='..' and not value:find('[/%z%c]')
end
local function entries(value,max)
    local result,seen={},{}
    for _i,item in ipairs(array(value,max)) do
        if type(item)~='table' or not basename(item.name) or seen[item.name] then fail() end
        seen[item.name]=true;result[#result+1]={name=item.name,info=stat(item.info)}
    end
    table.sort(result,function(a,b) return a.name<b.name end);return result
end
-- Only fixed names under the captured article parent survive the private pipe.
function M.check(value,root,key,opened)
    local parent=M.parent(root,key)
    if type(value)=='table' and value.root==root and value.key==key and value.missing==true and not parent and missing(root,key) then
        return {root=root,key=key,missing=true,items={},active=false,opened=opened}
    end
    if not parent or type(value)~='table' or value.root~=root or value.key~=key or type(value.state)~='table'
        or value.state.parent~=parent or type(value.state.unsafe)~='boolean'
        or not same(value.state.parent_info,fs().symlinkattributes(parent)) then fail() end
    local state={parent=parent,parent_info=stat(value.state.parent_info),entries=entries(value.state.entries,1024),
        bodies=entries(value.state.bodies,128),refs={},unsafe=value.state.unsafe==true}
    if type(value.state.refs)~='table' then fail() end
    local references=0
    for name,used in pairs(value.state.refs) do
        references=references+1;if not basename(name) or used~=true or references>1024 then fail() end;state.refs[name]=true
    end
    local plan={root=root,key=key,state=state,items={},active=false,opened=opened}
    local seen={}
    for _i,item in ipairs(array(value.items,512)) do
        if type(item)~='table' or not nonce(item.nonce) or seen[item.nonce] or not ({active=true,conflict=true,record=true,
            unknown_record=true,unknown=true,quarantine=true,protected=true,owned=true,completed=true})[item.status] then fail() end
        seen[item.nonce]=true
        local copy={nonce=item.nonce,status=item.status,bytes=0,kind=item.kind}
        if item.name then
            if not layout(key,item.nonce)[item.kind] or layout(key,item.nonce)[item.kind]~=item.name then fail() end
            copy.name=item.name;copy.info=stat(item.info)
        end
        if item.record_info then copy.record_info=stat(item.record_info);copy.bytes=copy.record_info.size end
        if item.status=='active' then plan.active=true end
        if item.contents then
            local source=item.contents
            if source.name~=copy.name or not same(source.info,copy.info) then fail() end
            local contents={name=copy.name,info=copy.info,files={},dirs={},bytes=0}
            local used={}
            for _j,file in ipairs(array(source.files,M.MAX_FILES)) do
                if type(file)~='table' or type(file.name)~='string' or used[file.name] then fail() end
                if not file.name:match('^body%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+%.html$')
                    and not file.name:match('^images/img%-%d%d%d%d%.[a-z]+$')
                    and not file.name:match('^images/bitmap%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+%.html$') then fail() end
                used[file.name]=true
                local info=stat(file.info);if info.mode~='file' then fail() end
                contents.files[#contents.files+1]={name=file.name,info=info};contents.bytes=contents.bytes+info.size
            end
            for _j,dir in ipairs(array(source.dirs,1)) do
                if dir.name~='images' then fail() end
                local info=stat(dir.info);if info.mode~='directory' then fail() end
                contents.dirs[#contents.dirs+1]={name=dir.name,info=info}
            end
            copy.contents=contents
            if copy.status~='completed' then copy.bytes=copy.bytes+contents.bytes end
        end
        plan.items[#plan.items+1]=copy
    end
    return plan
end
local function item_at(plan,n)
    for _i,item in ipairs(plan.items) do if item.nonce==n then return item end end
end
local function guard(job)
    if M.parent(job.plan.root,job.plan.key)~=job.plan.state.parent
        or not job.gate.fd or not same(job.gate.info,fs().symlinkattributes(job.gate.path))
        or not same(job.plan.state.parent_info,fs().symlinkattributes(job.plan.state.parent)) then return false end
    local expected={}
    for _i,entry in ipairs(job.plan.state.entries) do
        if not job.removed_parent[entry.name] then
            expected[entry.name]=true
            local now=fs().symlinkattributes(job.plan.state.parent..'/'..entry.name)
            if not same(entry.info,now) or entry.info.mode=='file' and not unchanged(entry.info,now) then return false end
        end
    end
    for _i,name in ipairs(names(job.plan.state.parent,1024)) do if name~='.mp-cleanup' and not expected[name] then return false end end
    if job.contents and not job.directory_done then
        local path=job.plan.state.parent..'/'..job.contents.name
        local expected_top,expected_images={},{}
        for _i,file in ipairs(job.contents.files) do
            if not job.removed[file.name] then
                local image=file.name:match('^images/(.+)$')
                if image then expected_images[image]=true else expected_top[file.name]=true end
            end
        end
        for _i,dir in ipairs(job.contents.dirs) do
            expected_top[dir.name]=true
            if not same(dir.info,fs().symlinkattributes(path..'/'..dir.name)) then return false end
            for _j,name in ipairs(names(path..'/'..dir.name,512)) do
                if not expected_images[name] then return false end;expected_images[name]=nil
            end
        end
        if next(expected_images) then return false end
        for _i,name in ipairs(names(path,3)) do if not expected_top[name] then return false end;expected_top[name]=nil end
        if next(expected_top) then return false end
    end
    return true
end
function M.begin(before,fresh,n,action,gate)
    if not gate or not gate.fd or fresh.active or not inventory_same(before.state,fresh.state) then fail() end
    local old,item=item_at(before,n),item_at(fresh,n)
    if not old or not item or old.status~=item.status or old.name~=item.name or not unchanged(old.record_info,item.record_info)
        or not (not old.info and not item.info or same(old.info,item.info)) then fail() end
    if type(fresh.opened)=='string' and item.name then
        local prefix=fresh.state.parent..'/'..item.name..'/'
        if fresh.opened:sub(1,#prefix)==prefix then fail() end
    end
    local lease,why=Lease.open(fresh.state.parent..'/'..M.record_name(n),{})
    if why=='busy' then fail() end
    local ok,job=pcall(function()
        local result={plan=fresh,item=item,gate=gate,lease=lease,action=action,index=1,removed={},removed_parent={},files=0,bytes=0}
        if action=='quarantine' then
            if item.status~='unknown' or item.kind~='pending' and item.kind~='generation'
                or not item.info or item.info.mode~='directory' or fresh.state.unsafe or fresh.state.refs[item.name] then fail() end
            result.destination=layout(fresh.key,n)[item.kind=='pending' and 'quarantine_pending' or 'quarantine_generation']
        elseif action=='restore' then
            if item.status~='quarantine' or item.kind~='quarantine_pending' and item.kind~='quarantine_generation' then fail() end
            result.destination=layout(fresh.key,n)[item.kind=='quarantine_pending' and 'pending' or 'generation']
        elseif action=='clean' then
            if not lease then fail() end
            local record=payload(lease,fresh.key,n,fresh.state.parent_info);if not record then fail() end
            if item.status=='owned' then
                if fresh.state.unsafe or fresh.state.refs[item.name] then fail() end
                local inspected=inspect(fresh.state.parent,item.name,record)
                if not inspected or not item.contents or #inspected.files~=#item.contents.files or #inspected.dirs~=#item.contents.dirs then fail() end
                for i,file in ipairs(inspected.files) do
                    if file.name~=item.contents.files[i].name or not unchanged(file.info,item.contents.files[i].info) then fail() end
                end
                result.contents=inspected
            elseif item.status=='completed' then
                local inspected=inspect(fresh.state.parent,item.name,record)
                if not inspected or not fresh.state.refs[item.name] then fail() end
                for _i,file in ipairs(inspected.files) do if file.name==record.body.name then fail() end end
            elseif item.status=='record' then
                for _i,name in pairs(layout(fresh.key,n)) do if fs().symlinkattributes(fresh.state.parent..'/'..name) then fail() end end
            else fail() end
        else fail() end
        if result.destination and fs().symlinkattributes(fresh.state.parent..'/'..result.destination) then fail() end
        if not guard(result) then fail() end;return result
    end)
    if not ok then if lease then lease:release() end;fail() end
    return job
end
function M.release(job)
    if job and job.lease then job.lease:release();job.lease=nil end
end
function M.step(job)
    if not guard(job) then return false,'changed' end
    local parent=job.plan.state.parent
    if job.destination then
        if not same(job.item.info,fs().symlinkattributes(parent..'/'..job.item.name)) or fs().symlinkattributes(parent..'/'..job.destination)
            or not os.rename(parent..'/'..job.item.name,parent..'/'..job.destination) then return false,'changed' end
        return true,'done'
    end
    for _i=1,16 do
        local contents=job.contents
        if contents and not job.directory_done then
            local path=parent..'/'..contents.name
            if not same(contents.info,fs().symlinkattributes(path)) then return false,'changed' end
            local file=contents.files[job.index]
            if file then
                if not unchanged(file.info,fs().symlinkattributes(path..'/'..file.name)) or not os.remove(path..'/'..file.name) then return false,'changed' end
                job.removed[file.name]=true
                job.files=job.files+1;job.bytes=job.bytes+file.info.size;job.index=job.index+1
            else
                for _j,dir in ipairs(contents.dirs) do
                    if not same(dir.info,fs().symlinkattributes(path..'/'..dir.name)) or not fs().rmdir(path..'/'..dir.name) then return false,'changed' end
                end
                if not fs().rmdir(path) then return false,'changed' end
                job.removed_parent[contents.name]=true;job.directory_done=true
            end
        else
            if not job.lease or not job.lease:remove() then return false,'changed' end
            job.files=job.files+1;job.bytes=job.bytes+job.lease.info.size
            job.removed_parent[M.record_name(job.item.nonce)]=true
            return true,'done'
        end
    end
    return true,'more'
end
return M

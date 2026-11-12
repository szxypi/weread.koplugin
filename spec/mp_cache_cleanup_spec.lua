package.path='./?.lua;'..package.path
local files,serial={},0
local held,remove_failed=false,false
local function put(path,data,mode)
    serial=serial+1;files[path]={mode=mode or 'file',data=data,size=data and #data or 0,dev=1,ino=serial,modification=serial}
end
local function info(path,key)
    local value=files[path];if not value then return nil end
    if key then return value[key] end
    local copy={};for k,v in pairs(value) do if k~='data' then copy[k]=v end end;return copy
end
local function names(parent)
    local rows={};for path in pairs(files) do
        if path:sub(1,#parent+1)==parent..'/' then
            local name=path:sub(#parent+2);if not name:find('/',1,true) then rows[#rows+1]=name end
        end
    end
    table.sort(rows);return rows
end
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=info,dir=function(parent)
    local rows=names(parent);local index=0;return function() index=index+1;return rows[index] end
end,rmdir=function(path) if #names(path)>0 then return nil end;files[path]=nil;return true end} end
local open,remove=io.open,os.remove
rawset(io,'open',function(path)
    local file=files[path];if not file or file.mode~='file' then return nil end
    return {read=function(_self,n) return file.data:sub(1,n) end,close=function() end}
end)
rawset(os,'remove',function(path) if remove_failed==true or remove_failed=='image' and path:find('/images/',1,true) then return nil end;files[path]=nil;return true end)
local Identity=require('weread.lib.mp_cache_identity')
local Cleanup=require('weread.lib.mp_cache_cleanup')
local root='/cache';local key=string.rep('a',64);local parent=root..'/mp-articles/'..key
local old='article.html';local active='article-2222222222222222.html'
local function generation(nonce) return '.weread-mp-'..key..'-assets-'..string.rep(nonce,16) end
Cleanup.open_lock=function(_root,_key,create)
    local path=parent..'/.mp-cleanup'
    if not files[path] then if not create then return nil,'absent' end;put(path,'') end
    if held then return nil,'busy' end
    held=true
    local lock={path=path,info=info(path),fd=9}
    function lock:release() held=false;self.fd=nil end
    return lock
end
local function image(nonce)
    local name=generation(nonce);local path=parent..'/'..name
    put(path,nil,'directory');put(path..'/images',nil,'directory');put(path..'/images/img-0001.png','PNG-'..nonce)
    return name
end
local function fixture(opened)
    files={};held=false;remove_failed=false
    put(root..'/mp-articles',nil,'directory');put(parent,nil,'directory')
    image('1');image('2');image('3')
    put(parent..'/'..old,Identity.marker(key)..'<img src="'..generation('1')..'/images/img-0001.png"/>')
    put(parent..'/'..active,Identity.marker(key)..'<img src="'..generation('2')..'/images/img-0001.png"/>')
    put(parent..'/current','weread-mp-current-v1\n'..active..'\n')
    put(parent..'/article.sdr',nil,'directory');put(parent..'/article.sdr/metadata.lua','retained reading notes')
    return Cleanup.check(Cleanup.scan(root,key,opened),root,key,opened)
end
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function begin(plan,selected)
    local lock=assert(Cleanup.acquire(root,key));local fresh=Cleanup.check(Cleanup.scan(root,key,plan.opened,lock.info),root,key,plan.opened)
    return Cleanup.begin(plan,selected,lock,fresh),lock
end
local plan=fixture();local target=Cleanup.targets(plan)
expect(#target.generations==1 and target.generations[1].name==generation('3') and target.bytes==5,'referenced images selected for cleanup')
local job,lock=begin(plan);local ok,reason=Cleanup.step(job);lock:release()
expect(ok and reason=='done' and job.removed_files==1 and job.removed_bytes==5,'unused cleanup counts wrong')
expect(files[parent..'/'..old] and files[parent..'/'..active] and not files[parent..'/'..generation('3')],'unused cleanup removed text or retained orphan')
plan=fixture();job,lock=begin(plan,old);ok,reason=Cleanup.step(job);lock:release()
expect(ok and reason=='done' and job.removed_files==3,'version cleanup did not include exclusive images and orphan')
expect(not files[parent..'/'..old] and not files[parent..'/'..generation('1')] and files[parent..'/'..generation('2')] and files[parent..'/'..active],'old cleanup changed current version')
expect(files[parent..'/article.sdr/metadata.lua'].data=='retained reading notes','old reading records deleted')
expect(not pcall(Cleanup.targets,fixture(),active),'current version deletable')
plan=fixture(parent..'/'..old)
expect(not pcall(Cleanup.targets,plan,old) and #Cleanup.targets(plan).generations==0,'opened article or its image generations deletable')
fixture();files[parent..'/'..active].data=files[parent..'/'..active].data..generation('1');files[parent..'/'..active].size=#files[parent..'/'..active].data
plan=Cleanup.scan(root,key,false);target=Cleanup.targets(plan,old)
expect(#target.generations==1 and target.generations[1].name==generation('3'),'shared image generation deleted with one version')
for _,change in ipairs({'parent','selector','active','old','image','image_directory','refs'}) do
    plan=fixture();lock=assert(Cleanup.acquire(root,key))
    if change=='parent' then put(parent,nil,'directory') elseif change=='selector' then put(parent..'/current','weread-mp-current-v1\n'..active..'\n')
    elseif change=='active' or change=='old' then local name=change=='active' and active or old;put(parent..'/'..name,files[parent..'/'..name].data)
    elseif change=='image' then put(parent..'/'..generation('3')..'/images/img-0001.png','PNG-x')
    elseif change=='image_directory' then put(parent..'/'..generation('3')..'/images',nil,'directory')
    else files[parent..'/'..old].data=files[parent..'/'..old].data:gsub(string.rep('1',16),string.rep('2',16)) end
    local good=pcall(function()
        local fresh=Cleanup.check(Cleanup.scan(root,key,false,lock.info),root,key,false)
        return Cleanup.begin(plan,old,lock,fresh)
    end)
    expect(not good,'stale preview accepted: '..change);lock:release()
end
for _,change in ipairs({'pending','unknown_html','image_link','unknown_image','generation_link'}) do
    fixture()
    if change=='pending' then put(parent..'/.mp-pending-123',nil,'directory')
    elseif change=='unknown_html' then put(parent..'/unknown.html','unknown refs')
    elseif change=='image_link' then put(parent..'/'..generation('3')..'/images/img-0001.png','outside','link')
    elseif change=='unknown_image' then put(parent..'/'..generation('3')..'/images/notes.txt','unknown')
    else put(parent..'/'..generation('3'),nil,'link') end
    expect(not pcall(Cleanup.scan,root,key,false),'unknown/symbolic work accepted: '..change)
end
plan=fixture();plan.generations[1].files[1].name='../escape.png'
expect(not pcall(Cleanup.check,plan,root,key,false),'pipe result granted arbitrary file path')
plan=fixture();plan.generations[1].files[2]=plan.generations[1].files[1]
expect(not pcall(Cleanup.check,plan,root,key,false),'duplicate pipe files accepted')
plan=fixture();job,lock=begin(plan,old);remove_failed=true
ok=Cleanup.step(job);expect(not ok and job.removed_files==0 and files[parent..'/'..old],'storage error reported deletion');lock:release()
plan=fixture();job,lock=begin(plan,old);remove_failed='image'
ok=Cleanup.step(job);expect(not ok and job.removed_files==1 and not files[parent..'/'..old]
    and files[parent..'/article.sdr/metadata.lua'] and files[parent..'/'..active],'partial deletion counts or retained notes wrong');lock:release()
plan=fixture();job,lock=begin(plan,old);lock:release();expect(not Cleanup.step(job) and files[parent..'/'..old],'released lock authorized deletion')
plan=fixture();job,lock=begin(plan,old);put(parent..'/unknown.html','new references')
expect(not Cleanup.step(job) and files[parent..'/'..old],'new unknown source not detected before deletion');lock:release()
local maximum=Cleanup.MAX_FILES;fixture();Cleanup.MAX_FILES=1
expect(not pcall(Cleanup.scan,root,key,false),'scan capacity ignored');Cleanup.MAX_FILES=maximum
plan=fixture();lock=assert(Cleanup.acquire(root,key));expect(Cleanup.locked(root,key),'active cleanup lock not detected')
lock:release();expect(not Cleanup.locked(root,key),'released persistent lock marker blocked future use')
fixture();for index=2,20 do put(parent..'/'..generation('3')..'/images/'..string.format('img-%04d.png',index),'pixels') end
plan=Cleanup.scan(root,key,false);job,lock=begin(plan)
ok,reason=Cleanup.step(job);expect(ok and reason=='more' and job.removed_files==16,'deletion not cooperatively bounded')
lock:release();expect(not Cleanup.step(job) and files[parent..'/'..active],'stopped batch continued after lock release')
fixture();put(parent..'/.mp-quarantine-pending-'..string.rep('f',16),nil,'directory')
plan=Cleanup.check(Cleanup.scan(root,key,false),root,key,false)
expect(plan.quarantined and #Cleanup.targets(plan).generations==0,'quarantined content lost image protection')
rawset(io,'open',open);rawset(os,'remove',remove)
print('PASS: MP cleanup reachability, snapshots, retention and deletion boundaries ('..checks..' checks)')

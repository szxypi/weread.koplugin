package.path='./?.lua;'..package.path
local files,serial,held,packets={},0,{},{}
local function put(path,data,mode)
    serial=serial+1;files[path]={data=data,mode=mode or 'file',dev=1,ino=serial,size=data and #data or 0,modification=serial}
end
local function info(path,key)
    local value=files[path];if not value then return nil end
    if key then return value[key] end
    local copy={};for k,v in pairs(value) do if k~='data' then copy[k]=v end end;return copy
end
local function children(parent)
    local rows={};for path in pairs(files) do
        if path:sub(1,#parent+1)==parent..'/' then local name=path:sub(#parent+2);if not name:find('/',1,true) then rows[#rows+1]=name end end
    end
    table.sort(rows);return rows
end
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=info,dir=function(parent)
    local rows=children(parent);local index=0;return function() index=index+1;return rows[index] end
end,rmdir=function(path) if #children(path)>0 then return nil end;files[path]=nil;return true end} end
local original_open,original_remove,original_rename=io.open,os.remove,os.rename
local remove_failed=false
rawset(io,'open',function(path)
    local file=files[path];if not file or file.mode~='file' then return nil end
    return {read=function(_self,n) return file.data:sub(1,n) end,close=function() end}
end)
rawset(os,'remove',function(path) if remove_failed and path:find('/images/',1,true) then return nil end;files[path]=nil;return true end)
rawset(os,'rename',function(from,to)
    if files[to] then return nil end
    local moved={};for path,value in pairs(files) do
        if path==from or path:sub(1,#from+1)==from..'/' then moved[to..path:sub(#from+1)]=value;files[path]=nil end
    end
    for path,value in pairs(moved) do files[path]=value end;return next(moved)~=nil
end)
local FileLease=require('weread.lib.file_lease')
FileLease.open=function(path,options)
    if options.exclusive and files[path] then return nil,'exists' end
    if not files[path] then if not options.create then return nil,'absent' end;put(path,'') end
    if files[path].mode~='file' then return nil,'unavailable' end
    if held[path] then return nil,'busy' end;held[path]=true
    local lease={path=path,info=info(path),fd=99}
    function lease:read() return files[path].data end
    function lease:write(raw) files[path].data=raw;files[path].size=#raw;self.info=info(path);return true end
    function lease:remove() files[path]=nil;return true end
    function lease:release() held[path]=nil;self.fd=nil end
    return lease
end
local Model=require('weread.lib.mp_download_recovery')
Model.codec={encode=function(value) local name='record-'..tostring(#packets+1);packets[#packets+1]=value;packets[name]=value;return name end,
    decode=function(raw) return assert(packets[raw]) end}
local Identity=require('weread.lib.mp_cache_identity')
local root,key='/cache',string.rep('a',64);local parent=root..'/mp-articles/'..key
local n=string.rep('1',16);local pending='.mp-pending-'..n;local generation='.weread-mp-'..key..'-assets-'..n
local body='body-20261109-120000-1.html';local record=parent..'/'..Model.record_name(n)
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture(leased)
    files={};held={};packets={};remove_failed=false
    put(root..'/mp-articles',nil,'directory');put(parent,nil,'directory')
    put(parent..'/article.html',Identity.marker(key)..'<p>Saved article</p>')
    put(parent..'/article.sdr',nil,'directory');put(parent..'/article.sdr/metadata.lua','saved notes')
    put(parent..'/'..pending,nil,'directory');put(parent..'/'..pending..'/images',nil,'directory')
    put(parent..'/'..pending..'/'..body,Identity.marker(key)..'<p>Unpublished</p>')
    put(parent..'/'..pending..'/images/img-0001.png','partial bitmap')
    local stage={parent=parent,key=key,parent_identity=info(parent),identity=info(parent..'/'..pending),
        images_identity=info(parent..'/'..pending..'/images'),output={path=parent..'/'..pending..'/'..body,identity=info(parent..'/'..pending..'/'..body)}}
    local lease=assert(Model.create(stage,n));if not leased then lease:release() end
    return lease
end
local function scan(opened) return Model.check(Model.scan(root,key,opened),root,key,opened) end
local function gate()
    if not files[parent..'/.mp-cleanup'] then put(parent..'/.mp-cleanup','') end
    return {fd=7,path=parent..'/.mp-cleanup',info=info(parent..'/.mp-cleanup')}
end
local function start(before,action,opened) return Model.begin(before,scan(opened),n,action,gate()) end
local lease=fixture(true);local plan=scan(false)
expect(plan.active and plan.items[1].status=='active','live attempt not identified')
expect(not pcall(start,plan,'clean',false),'live attempt deletable');lease:release()
plan=scan(false);expect(plan.items[1].status=='owned','inactive owned attempt not identified')
local job=start(plan,'clean',false);local ok,reason=Model.step(job);Model.release(job)
expect(ok and reason=='done' and job.files==3 and not files[parent..'/'..pending] and not files[record],'owned residue not completely cleaned')
expect(files[parent..'/article.html'] and files[parent..'/article.sdr/metadata.lua'].data=='saved notes','repair deleted saved body or notes')
fixture(false);plan=scan(parent..'/'..pending..'/'..body)
expect(plan.items[1].status=='protected' and not pcall(start,plan,'clean',parent..'/'..pending..'/'..body),'open temporary body deletable')
fixture(false);assert(os.rename(parent..'/'..pending,parent..'/'..generation))
assert(os.rename(parent..'/'..generation..'/'..body,parent..'/article-2222222222222222.html'))
files[parent..'/article-2222222222222222.html'].data=Identity.marker(key)..'<img src="'..generation..'/images/img-0001.png"/>'
files[parent..'/article-2222222222222222.html'].size=#files[parent..'/article-2222222222222222.html'].data
plan=scan(false);expect(plan.items[1].status=='completed' and plan.items[1].bytes==info(record).size,'published images not protected or record size wrong')
job=start(plan,'clean',false);ok=Model.step(job);Model.release(job)
expect(ok and job.files==1 and files[parent..'/'..generation..'/images/img-0001.png'] and files[parent..'/article-2222222222222222.html'],'completed cleanup removed content')
fixture(false);for path in pairs(files) do if path:sub(1,#parent+#pending+2)==parent..'/'..pending..'/' or path==parent..'/'..pending then files[path]=nil end end
plan=scan(false);expect(plan.items[1].status=='record','orphan ownership record not recognized')
job=start(plan,'clean',false);expect(Model.step(job) and not files[record],'orphan record not removed');Model.release(job)
fixture(false);files[record]=nil;put(parent..'/'..pending..'/personal.txt','keep me')
plan=scan(false);expect(plan.items[1].status=='unknown','legacy directory treated as owned')
expect(not pcall(start,plan,'clean',false),'unknown files could be deleted')
job=start(plan,'quarantine',false);expect(Model.step(job),'unknown quarantine failed');Model.release(job)
local quarantine='.mp-quarantine-pending-'..n
expect(files[parent..'/'..quarantine..'/personal.txt'].data=='keep me' and not files[parent..'/'..pending],'quarantine deleted or failed to move content')
plan=scan(false);expect(plan.items[1].status=='quarantine','quarantine lost discoverability')
job=start(plan,'restore',false);expect(Model.step(job),'quarantine restoration failed');Model.release(job)
expect(files[parent..'/'..pending..'/personal.txt'].data=='keep me' and not files[parent..'/'..quarantine],'restore did not keep original directory')
for _,change in ipairs({'schema','directory','body','images'}) do
    fixture(false)
    if change=='schema' then packets[1].schema=2 elseif change=='directory' then put(parent..'/'..pending,nil,'directory')
    elseif change=='body' then put(parent..'/'..pending..'/'..body,'replacement')
    else put(parent..'/'..pending..'/images',nil,'directory') end
    plan=scan(false);expect(plan.items[1].status=='unknown' and not pcall(start,plan,'clean',false),'unconfirmed ownership trusted: '..change)
end
fixture(false);put(parent..'/article.html',Identity.marker(key)..generation)
plan=scan(false);expect(plan.items[1].status=='owned','unrelated generation reference blocked pending cleanup')
put(parent..'/article.html',Identity.marker(key)..pending)
plan=scan(false);expect(plan.items[1].status=='protected','saved content references ignored')
fixture(false);plan=scan(false);put(parent..'/article.html',Identity.marker(key)..'<p>Replacement</p>')
expect(not pcall(start,plan,'clean',false),'changed cached content accepted old preview')
fixture(false);plan=scan(false);job=start(plan,'clean',false);put(parent..'/'..pending..'/unexpected.txt','preserve')
expect(not Model.step(job) and job.files==0 and files[parent..'/'..pending..'/unexpected.txt'],'new unknown file not protected');Model.release(job)
fixture(false);plan=scan(false);job=start(plan,'clean',false);remove_failed=true
expect(not Model.step(job) and job.files==1 and files[parent..'/'..pending..'/images/img-0001.png'],'partial failure counters wrong');Model.release(job)
remove_failed=false;plan=scan(false);job=start(plan,'clean',false);expect(Model.step(job),'partial recovery could not resume');Model.release(job)
fixture(false);plan=scan(false);plan.items[1].contents.files[1].name='../../saved.html'
expect(not pcall(Model.check,plan,root,key,false),'pipe result granted arbitrary path authority')
fixture(false);files[record]=nil;assert(os.rename(parent..'/'..pending,parent..'/'..generation))
files[parent..'/'..generation..'/'..body]=nil
expect(#scan(false).items==0,'normal committed generation shown as interrupted')
files={};expect(scan(false).missing and #scan(false).items==0,'never-downloaded article treated as a repair failure')
fixture(false);put(root..'/mp-articles',nil,'link')
expect(not pcall(Model.scan,root,key,false),'symbolic managed container reported as empty')
fixture(false);plan=scan(false);job=start(plan,'clean',false);put(root..'/mp-articles',nil,'link')
expect(not Model.step(job) and job.files==0,'managed container replaced by link after confirmation');Model.release(job)
fixture(false);plan=scan(false);plan.state.unsafe='false'
expect(not pcall(Model.check,plan,root,key,false),'malformed protection flag silently weakened safety')
fixture(false);local refs={Identity.marker(key)}
for index=1,1025 do refs[#refs+1]='.mp-pending-'..string.format('%016x',index) end
put(parent..'/article.html',table.concat(refs,' '))
expect(not pcall(Model.scan,root,key,false),'unbounded source references accepted')
rawset(io,'open',original_open);rawset(os,'remove',original_remove);rawset(os,'rename',original_rename)
print('PASS: interrupted download ownership, liveness, repair and quarantine ('..checks..' checks)')

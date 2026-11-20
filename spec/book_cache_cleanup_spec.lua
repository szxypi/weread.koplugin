-- Adversarial cache snapshots and retained opaque reading records.
package.path='./?.lua;'..package.path
local files,serial,tokens={},0,{}
local function put(path,data,mode)
    serial=serial+1;files[path]={mode=mode or 'file',data=data,size=data and #data or 0,dev=1,ino=serial,modification=serial}
end
local function info(path,key)
    local value=files[path];if not value then return nil end
    if key then return value[key] end
    local result={};for k,v in pairs(value) do if k~='data' then result[k]=v end end;return result
end
local function names(parent)
    local result={};for path in pairs(files) do
        if path:sub(1,#parent+1)==parent..'/' then
            local name=path:sub(#parent+2);if not name:find('/',1,true) then result[#result+1]=name end
        end
    end
    table.sort(result);return result
end
local held,remove_failed={},false
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=info,dir=function(path)
    local rows=names(path);local i=0;return function() i=i+1;return rows[i] end
end,rmdir=function(path) if #names(path)>0 then return nil end;files[path]=nil;return true end} end
package.preload['weread.lib.book_operation']=function() return {NAME='.weread-book-operation',
    path=function(path) return type(path)=='string' and path:sub(1,1)=='/' and not path:find('..',1,true) and path..'/.weread-book-operation' or nil end,
    open=function(root)
        if held[root] then return nil,'busy' end
        held[root]=true
        return {owns=function() return held[root] end,release=function() held[root]=false end}
    end} end
package.preload['weread.lib.mp_cache_cleanup']=function() return {open_lock=function(root,key)
    local path=root..'/mp-articles/'..key..'/.mp-cleanup'
    if held[path] then return nil,'busy' end
    put(path,'');held[path]=true
    return {owns=function() return held[path] end,release=function() held[path]=false end}
end} end
local open,remove=io.open,os.remove
rawset(io,'open',function(path)
    local entry=files[path];if not entry or entry.mode~='file' then return nil end
    return {read=function(_self,n) return type(n)=='number' and entry.data:sub(1,n) or entry.data end,close=function() end}
end)
rawset(os,'remove',function(path)
    if remove_failed then return nil end
    files[path]=nil;return true
end)
package.preload.json=function() return {decode=function(raw) return assert(tokens[raw]) end} end
local Model=require('weread.lib.book_cache_cleanup')
local root='/cache/900001'
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    files={};held={};remove_failed=false
    put(root,nil,'directory')
    put(root..'/metadata.json','valid')
    tokens.valid={book_id='900001',cached_full_book=root..'/full.epub',cached_chapters={['2']=root..'/chapter.epub'}}
    put(root..'/reading_state.json','opaque dispatch journal and pending positions')
    put(root..'/reading_state.json.tmp','opaque concurrent checkpoint')
    put(root..'/full.sdr',nil,'directory');put(root..'/full.sdr/metadata.epub.lua','opaque native notes')
    put(root..'/full.epub','full');put(root..'/chapter.epub','chapter')
    put(root..'/catalog.json','catalog');put(root..'/articles.json','articles')
    put(root..'/resources',nil,'directory');put(root..'/resources/image.png','image')
    return Model.scan(root,'900001')
end
local function begin(plan)
    local lease,fresh=Model.acquire(root,'900001');assert(lease)
    expect(Model.same_plan(plan,fresh),'unchanged preview rejected')
    return {plan=fresh,lease=lease,files=0,bytes=0}
end
expect(not Model.retained('Synthetic.lua.epub',false) and not Model.retained('Synthetic.json.html',false),'book title mistaken for reading records')
local plan=fixture();expect(plan.files==5 and plan.bytes==31,'download accounting included reading records')
local job=begin(plan);local ok,reason=Model.step(job,2)
expect(ok and reason=='continue' and job.files==2,'cleanup did not yield after the bounded step')
while ok and reason~='done' do ok,reason=Model.step(job,2) end;job.lease:release()
expect(ok and reason=='done' and job.files==5 and not files[root..'/full.epub'],'download deletion incomplete')
expect(files[root..'/reading_state.json'].data=='opaque dispatch journal and pending positions'
    and files[root..'/reading_state.json.tmp'] and files[root..'/full.sdr/metadata.epub.lua'],'reading journal or native notes erased')
expect(Model.scan(root,'900001').files==0,'record-only book counted as downloaded content')
for _,change in ipairs({'id','conflict','paths','chapter_type','annotation_type','outside_annotation','root_name','link','pending','download','capacity'}) do
    fixture();local scanroot=root
    if change=='id' then tokens.valid.book_id='900002'
    elseif change=='conflict' then tokens.valid.bookId='900002'
    elseif change=='paths' then tokens.valid.cached_full_book='/elsewhere/book.epub'
    elseif change=='chapter_type' then tokens.valid.cached_chapters='bad'
    elseif change=='annotation_type' then tokens.valid.annotation_documents=42
    elseif change=='outside_annotation' then tokens.valid.annotation_documents={['/elsewhere/book.epub']={}}
    elseif change=='root_name' then scanroot='/cache'
    elseif change=='link' then put(root..'/resources/linked','outside','link')
    elseif change=='pending' then put(root..'/.mp-pending-test',nil,'directory')
    elseif change=='download' then put(root..'/.mp-download-test','live ownership record')
    else Model.MAX_ENTRIES=1 end
    expect(not pcall(Model.scan,scanroot,'900001'),'unsafe cache accepted: '..change)
    Model.MAX_ENTRIES=16384
end
for _,change in ipairs({'root','directory','content','metadata','new_file'}) do
    plan=fixture()
    if change=='root' then put(root,nil,'directory')
    elseif change=='directory' then put(root..'/resources',nil,'directory')
    elseif change=='content' then put(root..'/full.epub','new full')
    elseif change=='metadata' then put(root..'/metadata.json','other');tokens.other=tokens.valid
    else put(root..'/new.epub','new') end
    local lease,fresh=Model.acquire(root,'900001');assert(lease)
    expect(not Model.same_plan(plan,fresh),'stale preview authorized deletion: '..change);lease:release()
end
plan=fixture();job=begin(plan);put(root..'/reading_state.json','new journal while cleanup is pending')
ok,reason=Model.step(job);job.lease:release()
expect(ok and reason=='done' and files[root..'/reading_state.json'].data=='new journal while cleanup is pending','concurrent journal update was lost')
plan=fixture();job=begin(plan);job.lease:release()
expect(not Model.step(job) and files[root..'/full.epub'],'released lease allowed deletion')
plan=fixture();job=begin(plan);put(root..'/resources',nil,'directory')
expect(not Model.step(job) and files[root..'/resources/image.png'],'replaced parent directory allowed deletion');job.lease:release()
plan=fixture();job=begin(plan);put(root..'/metadata.json','other');tokens.other=tokens.valid
expect(not Model.step(job) and files[root..'/full.epub'],'changed metadata allowed deletion');job.lease:release()
plan=fixture();job=begin(plan);remove_failed=true
expect(not Model.step(job) and job.files==0 and files[root..'/full.epub'],'storage failure was reported as success');job.lease:release()
plan=fixture();job=begin(plan);ok=Model.step(job,1);remove_failed=true
expect(ok and not Model.step(job) and job.files==1 and files[root..'/reading_state.json'],'partial failure lost records or accounting');job.lease:release()
fixture();held[root]=true
expect(not Model.acquire(root,'900001') and files[root..'/full.epub'],'concurrent book writer ignored')
fixture();local key=string.rep('a',64);local parent=root..'/mp-articles/'..key
put(root..'/mp-articles',nil,'directory');put(parent,nil,'directory');put(parent..'/article.html','article')
plan=Model.scan(root,'900001');local lease,fresh=Model.acquire(root,'900001')
expect(lease and Model.same_plan(plan,fresh),'new MP item gate invalidated an unchanged preview');lease:release()
held[parent..'/.mp-cleanup']=true
expect(not Model.acquire(root,'900001') and not held[root],'busy MP article did not release book gate')
fixture();put(root..'/.mp-quarantine-test',nil,'directory');put(root..'/.mp-quarantine-test/unknown','protected')
plan=Model.scan(root,'900001');job=begin(plan);ok=Model.step(job);job.lease:release()
expect(ok and files[root..'/.mp-quarantine-test/unknown'],'quarantined recovery data erased')
rawset(io,'open',open);rawset(os,'remove',remove)
print(('book_cache_cleanup_spec: %d checks'):format(checks))

package.path='./?.lua;'..package.path
local files,serial,state={},0,{}
local function put(path,data,mode)
    serial=serial+1;files[path]={data=data,mode=mode or 'file',dev=1,ino=serial,size=data and #data or 0,modification=serial}
end
local function info(path,key)
    local entry=files[path];if not entry then return nil end
    if key then return entry[key] end
    local copy={};for k,v in pairs(entry) do if k~='data' then copy[k]=v end end;return copy
end
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=info,dir=function(parent)
    local names={};for path in pairs(files) do
        local name=path:sub(1,#parent+1)==parent..'/' and path:sub(#parent+2)
        if name and not name:find('/',1,true) then names[#names+1]=name end
    end
    local i=0;return function() i=i+1;return names[i] end
end} end
local old_open,old_rename=io.open,os.rename
rawset(io,'open',function(path)
    local entry=files[path];if not entry or entry.mode~='file' then return nil end
    return {read=function(_self,count) return entry.data:sub(1,count) end,close=function() end}
end)
rawset(os,'rename',function(from,to)
    if state.rename_failed then return nil end
    files[to]=files[from];files[from]=nil;return true
end)
package.preload['weread.lib.notes_export_file']=function() return {create=function(parent)
    if state.create_failed then return nil end
    local path=parent..'/temporary';put(path,'')
    return {path=path,write=function(_self,raw)
        put(path,raw)
        if state.concurrent then state.concurrent() end
        return true
    end,sync=function() return not state.sync_failed end,accept=function() return not state.accept_failed end,
        abort=function() files[path]=nil end}
end} end
local Identity=require('weread.lib.mp_cache_identity')
local Versions=require('weread.lib.mp_cache_versions')
local key=string.rep('a',64);local root='/cache';local parent=root..'/mp-articles/'..key
local original=parent..'/article.html';local name='article-0123456789abcdef.html';local next_path=parent..'/'..name
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    files={};state={};put(root..'/mp-articles',nil,'directory');put(parent,nil,'directory')
    put(original,Identity.marker(key)..'<p>Old body</p>');put(next_path,Identity.marker(key)..'<p>New body</p>')
    return assert(Versions.capture(root,key))
end
local snapshot=fixture()
expect(Versions.matches(snapshot),'fresh snapshot mismatched')
expect(select(2,Versions.resolve(root,key))=='none','missing selector did not retain base lookup')
expect(Versions.publish(snapshot,name),'new selector publication failed')
expect(Versions.resolve(root,key)==next_path,'published path not resolved')
expect(Versions.contains(root,key,original) and Versions.contains(root,key,next_path),'saved versions not recognized')
expect(not Versions.contains(root,key,parent..'/../article.html'),'traversing historical path accepted')
expect(not Versions.contains(root,string.rep('b',64),next_path),'historical version crossed article identity')
expect(files[original].data:find('Old body',1,true),'publication changed original body')
expect(not Versions.matches(snapshot),'old selector snapshot remained current')
local entries=assert(Versions.list(root,key))
expect(#entries==2 and entries[1].path==next_path and entries[1].current and not entries[2].current,'history not current-first')
for _,change in ipairs({'create_failed','sync_failed','accept_failed','rename_failed'}) do
    snapshot=fixture();state[change]=true
    expect(not Versions.publish(snapshot,name) and not files[parent..'/current'] and Versions.matches(snapshot),'failed publication changed selection: '..change)
end
for _,bad in ipairs({'../article-0123456789abcdef.html','article-ABCDEF0123456789.html','article-abc.html','article.html','/outside'}) do
    snapshot=fixture();expect(not Versions.publish(snapshot,bad),'unsafe revision name accepted')
end
snapshot=fixture();put(next_path,'wrong marker')
expect(not Versions.publish(snapshot,name),'foreign body accepted')
snapshot=fixture();state.concurrent=function() put(parent..'/current','weread-mp-current-v1\narticle-fedcba9876543210.html\n') end
expect(not Versions.publish(snapshot,name) and files[parent..'/current'].data:find('fedcba9876543210',1,true),'publication overwrote replaced selector')
snapshot=fixture();put(original,Identity.marker(key)..'<p>Replacement</p>')
expect(not Versions.matches(snapshot) and not Versions.publish(snapshot,name),'replaced base accepted')
snapshot=fixture();put(parent,nil,'directory')
expect(not Versions.matches(snapshot),'replaced managed parent accepted')
for _,bad in ipairs({'','weread-mp-current-v1\n../outside\n','weread-mp-current-v1\n'..name..'\nextra',string.rep('x',129)}) do
    fixture();put(parent..'/current',bad)
    local path,reason=Versions.resolve(root,key)
    expect(not path and reason=='invalid' and not Versions.capture(root,key),'corrupt selector fell back')
end
for _,bad in ipairs({parent,parent..'/current',next_path}) do
    snapshot=fixture();assert(Versions.publish(snapshot,name));put(bad,'ignored','link')
    expect(not Versions.resolve(root,key) and (bad~=parent or not Versions.contains(root,key,next_path)),'symlink revision/selector/parent followed')
end
snapshot=fixture();assert(Versions.publish(snapshot,name));files[next_path]=nil
expect(not Versions.capture(root,key) and select(2,Versions.resolve(root,key))=='invalid','missing current target fell back to stale body')
fixture();local maximum=Versions.MAX_VERSIONS;Versions.MAX_VERSIONS=1
expect(not Versions.list(root,key),'version capacity ignored');Versions.MAX_VERSIONS=maximum
maximum=Versions.MAX_ENTRIES;Versions.MAX_ENTRIES=1
expect(not Versions.list(root,key),'directory capacity ignored');Versions.MAX_ENTRIES=maximum
fixture();put(parent..'/article-fedcba9876543210.html',Identity.marker(string.rep('b',64)))
expect(#assert(Versions.list(root,key))==2,'foreign-marker revision listed')
local function p16(n) return string.char(n%256,math.floor(n/256)%256) end
local function p32(n) return p16(n%65536)..p16(math.floor(n/65536)) end
local function epub_header(owner,revision)
    local function local_header(path,body,extra)
        return 'PK\3\4'..p16(20)..p16(0)..p16(0)..p32(0)..p32(0)..p32(#body)..p32(#body)
            ..p16(#path)..p16(#extra)..path..extra..body
    end
    local marker='weread-mp-epub-v1\n'..owner..'\n'..revision..'\n'
    return local_header('mimetype','application/epub+zip','')
        ..local_header('META-INF/container.xml','<container/>',p16(0x5752)..p16(#marker)..marker)
end
snapshot=fixture();local epub_name='article-0123456789abcdef.epub';local epub_path=parent..'/'..epub_name
put(epub_path,epub_header(key,'0123456789abcdef'))
expect(Versions.publish(snapshot,epub_name) and Versions.resolve(root,key)==epub_path,'independent EPUB could not become current')
expect(Versions.contains(root,key,epub_path) and #assert(Versions.list(root,key))==3,'EPUB disappeared from mixed-format history')
put(epub_path,epub_header(key,'fedcba9876543210'))
expect(not Versions.resolve(root,key) and not Versions.contains(root,key,epub_path),'EPUB filename/identity mismatch accepted')
put(epub_path,epub_header(string.rep('b',64),'0123456789abcdef'))
expect(not Versions.resolve(root,key),'foreign EPUB identity accepted')
put(epub_path,epub_header(key,'0123456789abcdef'));files[epub_path].size=72*1024*1024+1
expect(not Versions.resolve(root,key),'EPUB file-size bound ignored')
expect(not Versions.name_ok('article-0123456789abcdef.zip') and not Versions.name_ok('article-0123456789abcdef.epub/extra'),'unmanaged archive extension/path accepted')
rawset(io,'open',old_open);rawset(os,'rename',old_rename)
print('PASS: immutable MP cache versions and selector boundaries ('..checks..' checks)')

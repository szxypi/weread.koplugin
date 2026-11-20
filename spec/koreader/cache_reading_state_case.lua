-- Standalone native-runtime real files; each phase runs in a fresh process.
for _i,name in ipairs({'ui/widget/buttondialog','ui/widget/confirmbox','ui/widget/pathchooser'}) do
    package.preload[name]=function() return {new=function(_self,options) return options end} end
end
package.preload['ui/uimanager']=function() return {show=function() end} end
package.preload['weread.lib.logger']=function() return {info=function() end,warn=function() end,err=function() end} end
package.preload['weread.lib.scan']=function() return {} end
package.preload.readcollection=function() return {coll={},removeItem=function() return true end,write=function() end} end
local function read(path)
    local file=io.open(path,'rb');if not file then return nil end
    local raw=file:read('*a');file:close();return raw
end
local function write(path,raw) local file=assert(io.open(path,'wb'));assert(file:write(raw));file:close() end
package.preload['weread.lib.plugin_util']=function() return {
    tr=function(value) return value end,T=function(value) return value end,
    file_exists=function(path) return type(path)=='string' and read(path)~=nil end,log_error=tostring,display_error=tostring,
} end
local lfs=require('libs/libkoreader-lfs')
local Settings=require('weread.lib.settings')
local Store=require('weread.lib.book_store')
local Model=require('weread.lib.book_cache_cleanup')
local Operation=require('weread.lib.book_operation')
local Cache=require('weread.ui.cache')
local json=require('json')
local settings=Settings:new()
local host={settings=settings,clearBookAnnotationData=function() return true end,refreshShelfCacheIndicators=function() end}
for key,value in pairs(Cache) do if not host[key] then host[key]=value end end
local root=settings.data_dir;local manifest_path=root..'/synthetic-cache-check.json'
local ids={'900001','900002','900003','CB_synthetic','MP_WXS_900001'}
local function manifest() return json.decode(assert(read(manifest_path))) end
local function verify(expected,content)
    local indexes=settings:get_book_indexes()
    local count=0
    for id,index in pairs(indexes) do
        count=count+1;assert(expected.indexes[id] and index.cache_dir==expected.indexes[id].cache_dir,'book index route changed')
        for key in pairs(index) do assert(key=='cache_dir','book index gained data') end
    end
    assert(count==#ids,'book index count changed')
    for _,id in ipairs(ids) do
        local saved=settings:get_book(id);local dir=assert(saved.cache_dir)
        assert(read(dir..'/reading_state.json')==expected.states[id],'reading-state bytes changed')
        assert(read(dir..'/full.sdr/metadata.epub.lua')=='synthetic native notes','native notes changed')
        assert((read(dir..'/full.epub')~=nil)==content,'content presence mismatch')
        if not content then
            assert(not saved.cached_file and not saved.cached_full_book and not next(saved.cached_chapters or {}),'deleted file pointers retained')
            assert(Model.scan(dir,id).files==0,'retained records counted as content')
        end
    end
end
local phase=os.getenv('WEREAD_CACHE_TEST_PHASE')
if phase=='setup' then
    settings:set('account',{user_vid='900000',login_time=1});settings:flush()
    local books={}
    for _,id in ipairs(ids) do
        local dir=settings.cache_dir..'/'..id
        books[id]={book_id=id,title='Synthetic cache book',progress=37,
            last_local_position={chapter_uid='2',chapter_offset=17,percent=37},
            pending_upload_position={chapter_uid='2',chapter_offset=17,percent=37},
            pending_upload_account='synthetic-account',source_dispatch={schema=1,id=string.rep('a',32)},
            cached_full_book=dir..'/full.epub',cached_file=dir..'/full.epub',cached_chapters={['2']=dir..'/chapter.epub'}}
    end
    settings:set('books',books);settings:flush()
    local result={states={},indexes=settings:get_book_indexes()}
    for _,id in ipairs(ids) do
        local dir=settings.cache_dir..'/'..id
        write(dir..'/full.epub','synthetic full book');write(dir..'/chapter.epub','synthetic chapter')
        write(dir..'/catalog.json','synthetic catalog');assert(lfs.mkdir(dir..'/full.sdr'))
        write(dir..'/full.sdr/metadata.epub.lua','synthetic native notes')
        if id=='900003' then write(dir..'/reading_state.json','opaque unrecognized journal; retain verbatim') end
        result.states[id]=assert(read(dir..'/reading_state.json'))
    end
    write(manifest_path,json.encode(result));verify(result,true)
elseif phase=='hold' then
    local lease=assert(Operation.prepare(settings.cache_dir..'/900001'))
    io.stdout:write('CACHE_GATE_HELD\n');io.stdout:flush();assert(io.stdin:read('*l')=='release');lease:release()
elseif phase=='contend' then
    local lease,reason=Operation.prepare(settings.cache_dir..'/900001')
    assert(not lease and reason=='busy','independent download gate bypassed cleanup')
    assert(not host:clearBookCache('900001'),'independent cleanup bypassed download gate')
    verify(manifest(),true)
elseif phase=='clear' then
    local expected=manifest()
    assert(host:clearAllMPCache(),'MP cleanup failed')
    assert(not read(settings.cache_dir..'/MP_WXS_900001/full.epub'),'MP content survived')
    assert(read(settings.cache_dir..'/900001/full.epub'),'MP cleanup removed normal book')
    assert(host:clearAllCache(),'bulk cleanup failed');verify(expected,false)
elseif phase=='inspect' then
    local expected=manifest();verify(expected,false)
    local book=settings:get_book('900001')
    assert(book.last_local_position.chapter_offset==17 and book.pending_upload_position.chapter_offset==17 and book.source_dispatch,'positions or replay journal lost on restart')
    write(book.cache_dir..'/full.epub','synthetic replacement book')
    book.cached_file=book.cache_dir..'/full.epub';book.cached_full_book=book.cached_file
    assert(Store.save(settings,'900001',book),'download metadata save failed')
    local refreshed=settings:get_book('900001')
    assert(refreshed.last_local_position.chapter_offset==17 and refreshed.pending_upload_position.chapter_offset==17 and refreshed.source_dispatch,'redownload lost records')
    assert(read(book.cache_dir..'/full.sdr/metadata.epub.lua')=='synthetic native notes','redownload lost notes')
else error('unknown synthetic phase') end
print('CACHE_RECORD_PHASE_OK:'..phase)

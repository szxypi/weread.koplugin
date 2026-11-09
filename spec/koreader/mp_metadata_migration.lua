-- Actual KOReader location menu, ReaderUI annotations, close/flush and reopen.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader')
Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UIManager=require('ui/uimanager');UIManager:setRunForeverMode();UIManager:setInputTimeout(0)
local Reader=require('apps/reader/readerui')
local Doc=require('docsettings')
local Settings=require('weread.lib.settings')
local Identity=require('weread.lib.mp_cache_identity')
local Stage=require('weread.lib.mp_download_stage')
local Download=require('weread.lib.mp_download')
local Versions=require('weread.lib.mp_cache_versions')
local Crypto=require('weread.lib.crypto')
local lfs=require('libs/libkoreader-lfs')
local json=require('json')
local settings=Settings:new()
assert(settings.mock_endpoint,'synthetic profile required')
settings:set('sync',{pull_on_open=false,upload_on_close=false})
settings:set('read_report',{enabled=false})
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.show_annotations=false
cache.download_mp_images=false;settings:set('cache',cache);settings:flush()
local locations={'doc','dir','hash'}
local menu=require('ui/elements/common_settings_menu_table').document_metadata_location.sub_item_table
local function clean_popups(reader)
    while UIManager:getTopmostVisibleWidget() and UIManager:getTopmostVisibleWidget()~=reader do
        UIManager:close(UIManager:getTopmostVisibleWidget())
    end
end
local function choose(location)
    local selected
    for index,name in ipairs(locations) do if name==location then selected=menu[index+1] end end
    assert(selected);selected.callback();clean_popups()
    assert(G_reader_settings:readSetting('document_metadata_folder','doc')==location and selected.checked_func())
end
local function bytes(path)
    local file=assert(io.open(path,'rb'));local raw=file:read('*a');file:close();return raw
end
local function write(path,value)
    local file=assert(io.open(path,'wb'));assert(file:write(json.encode(value)));file:close()
end
local function projection(rows)
    local result={}
    for _,row in ipairs(rows) do
        result[#result+1]={page=row.page,pos0=row.pos0,pos1=row.pos1,drawer=row.drawer,
            text=row.text,note=row.note,datetime=row.datetime}
    end
    table.sort(result,function(a,b) return tostring(a.drawer or '')<tostring(b.drawer or '') end)
    return result
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for key,value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local reader,reader_opens=nil,0
local function open(entry)
    reader=Reader:new{dimen=Device.screen:getSize(),document=require('document/documentregistry'):openDocument(entry.path)}
    UIManager:show(reader)
    reader_opens=reader_opens+1
    assert(reader.weread and reader.weread:detectWeReadBook()==entry.book_id,'version lost MP container identity')
    assert(reader.document:getPageCount()>=8,'migration fixture has insufficient pages')
    return reader
end
local function close()
    clean_popups(reader);reader:onClose(false);reader=nil
end
local function verify_pending(entry)
    local book=assert(Settings:new():get('books',{})[entry.book_id])
    assert(book.progress==.45 and same(book.pending_upload_position,{offset=23}),
        'metadata operation changed persisted progress or pending upload state')
end
local function verify(entry)
    local value=open(entry)
    assert(same(projection(value.annotation.annotations),entry.annotations),'ReaderUI notes changed or mixed versions')
    assert(value.doc_settings:readSetting('last_xpointer')==entry.xpointer,'stored reading position changed')
    assert(value.document:isXPointerInCurrentPage(entry.xpointer),'ReaderUI did not restore saved page')
    UIManager:forceRePaint();close()
    local stored=Doc:open(entry.path)
    assert(stored:readSetting('last_xpointer')==entry.xpointer and same(projection(stored:readSetting('annotations')),entry.annotations),
        'closing the reopened ReaderUI changed reading records')
    assert(Crypto.sha256_hex(bytes(entry.path))==entry.body_sha256,'metadata operation rewrote immutable HTML')
    verify_pending(entry)
end
local old_location=G_reader_settings:readSetting('document_metadata_folder','doc')
local manifest_path=evidence..'/mp-metadata-migration-fixtures.json'
local report={result='UNVERIFIED',synthetic_only=true,actual_reader=true,actual_location_menu=true,transitions={},
    account_requests=0,account_data_writes=0}
if arg[1]=='migrate' then
    settings:set('books',{});settings:flush()
    local entries={};local case_index=0
    for _,source in ipairs(locations) do
        for _,target in ipairs(locations) do
            if source~=target then
                case_index=case_index+1;choose(source)
                local book={book_id='MP_WXS_'..(990100+case_index),title='合成记录迁移 '..source..' '..target,
                    cache_dir=settings.data_dir..'/metadata-migration-'..source..'-'..target,
                    progress=.45,pending_upload_position={offset=23}}
                local article={reviewId='migration-fixture',title='文章多版本与笔记'};book.mp_articles={article}
                local books=settings:get('books',{});books[book.book_id]=book;settings:set('books',books);settings:flush()
                local key=assert(Identity.key(book,article));local batch={}
                for version=1,3 do
                    local paragraphs={}
                    for index=1,120 do
                        paragraphs[#paragraphs+1]='<p>段落 '..index..' '..string.rep('这段合成文字用于验证原生阅读位置和划线记录。',8)..'</p>'
                    end
                    paragraphs[60]=paragraphs[60]..'<p>'..(version==1 and 'OLDTEXT' or 'NEWTEXT')..'</p>'
                    local input=assert(Download.capture(settings,book,article))
                    local stage=assert(Stage.create(book.cache_dir,key,{preserve=version>1}))
                    local transport={request=function(_self,options)
                        assert(options.method=='GET' and options.diagnostic_api=='mp_read')
                        assert(options.sink('<div id="js_content">'..table.concat(paragraphs)..'</div>'));return nil,200
                    end}
                    local path=assert(stage:commit(Download.write(transport,input,stage,{missing='Unavailable'})))
                    local entry={path=path,book_id=book.book_id,source=source,target=target,version=version,
                        body_sha256=Crypto.sha256_hex(bytes(path))}
                    local value=open(entry)
                    assert(#value.annotation.annotations==0,'new version inherited another version annotations')
                    value.rolling:onGotoPage(version+1);value.bookmark:onToggleBookmark()
                    local selected=assert(value.document:getTextFromPositions({x=1,y=1},
                        {x=Device.screen:getWidth()-2,y=Device.screen:getHeight()-2},true))
                    value.annotation:addItem{page=selected.pos0,pos0=selected.pos0,pos1=selected.pos1,
                        text=selected.text,note='合成附注 '..source..' '..target..' '..version,drawer='lighten',
                        datetime='2026-11-09 12:00:00'}
                    entry.annotations=projection(value.annotation.annotations);assert(#entry.annotations==2)
                    close()
                    verify_pending(entry)
                    local stored=Doc:open(path);entry.xpointer=assert(stored:readSetting('last_xpointer'))
                    entry.source_sidecar=assert(Doc:findSidecarFile(path))
                    local _,found=Doc:findSidecarFile(path);assert(found==source)
                    batch[#batch+1]=entry;entries[#entries+1]=entry
                end
                assert(#Versions.list(book.cache_dir,key)==3)
                assert(batch[1].xpointer~=batch[2].xpointer and batch[2].xpointer~=batch[3].xpointer,'versions did not save distinct positions')
                choose(target)
                for _,entry in ipairs(batch) do
                    verify(entry)
                    local path,found=Doc:findSidecarFile(entry.path)
                    assert(found==target and path~=entry.source_sidecar and not lfs.attributes(entry.source_sidecar),
                        'record did not migrate to selected location or left an old candidate')
                end
                report.transitions[#report.transitions+1]={source=source,target=target,versions=3,
                    notes_preserved=true,positions_restored=true,old_location_removed=true,html_unchanged=true,pending_preserved=true}
            end
        end
    end
    write(manifest_path,entries);report.version_files=#entries
else
    assert(arg[1]=='reopen','expected migrate or reopen')
    local entries=json.decode(bytes(manifest_path));assert(#entries==18)
    for _,entry in ipairs(entries) do
        choose(entry.target);verify(entry)
        local _,found=Doc:findSidecarFile(entry.path);assert(found==entry.target)
    end
    report.fresh_process=true;report.version_files=#entries
end
choose(old_location);G_reader_settings:flush()
report.reader_opens=reader_opens
assert(reader_opens==(arg[1]=='migrate' and 36 or 18),'unexpected ReaderUI open count')
report.result='PASS';write(evidence..'/mp-metadata-'..arg[1]..'.json',report)
print('PASS: native article metadata '..arg[1]..', '..report.version_files..' independent versions')

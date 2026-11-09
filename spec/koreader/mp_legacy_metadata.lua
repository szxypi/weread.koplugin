-- Synthetic collision control and explicit snapshot recovery via real ReaderUI.
-- This is an acceptance prototype, not an automatic product recovery path.
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
local Content=require('weread.lib.content')
local Versions=require('weread.lib.mp_cache_versions')
local Crypto=require('weread.lib.crypto')
local lfs=require('libs/libkoreader-lfs')
local util=require('util')
local json=require('json')
local settings=Settings:new();assert(settings.mock_endpoint,'synthetic profile required')
local title=arg[1]=='title' or arg[1]=='title-reopen'
local product=arg[1]=='product' or arg[1]=='product-reopen' or title
if product then settings:set('account',{user_vid='900000',login_method='qr'}) end
settings:set('sync',{pull_on_open=false,upload_on_close=false});settings:set('read_report',{enabled=false})
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.show_annotations=false
settings:set('cache',cache);settings:flush()
local menu=require('ui/elements/common_settings_menu_table').document_metadata_location.sub_item_table
local locations={'doc','dir','hash'}
local function clean(reader)
    while UIManager:getTopmostVisibleWidget() and UIManager:getTopmostVisibleWidget()~=reader do
        UIManager:close(UIManager:getTopmostVisibleWidget())
    end
end
local function choose(location,reader)
    for index,name in ipairs(locations) do
        if name==location then menu[index+1].callback();clean(reader);assert(menu[index+1].checked_func());return end
    end
    error('unknown test location')
end
local function read(path)
    local file=assert(io.open(path,'rb'));local value=file:read('*a');file:close();return value
end
local function write(path,value)
    local file=assert(io.open(path,'wb'));assert(file:write(value));file:close()
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for key,value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function projection(rows)
    local result={}
    for _,row in ipairs(rows or {}) do
        result[#result+1]={page=row.page,pos0=row.pos0,pos1=row.pos1,drawer=row.drawer,
            text=row.text,note=row.note,datetime=row.datetime}
    end
    table.sort(result,function(a,b) return tostring(a.drawer or '')<tostring(b.drawer or '') end)
    return result
end
local opens=0
local function open(path)
    local value=Reader:new{dimen=Device.screen:getSize(),document=require('document/documentregistry'):openDocument(path)}
    UIManager:show(value);opens=opens+1
    assert(value.weread and value.weread:detectWeReadBook()=='MP_WXS_990081')
    assert(value.document:getPageCount()>=6,'insufficient synthetic pages')
    return value
end
local function close(value)
    clean(value);value:onClose(false)
    local stored=assert(Settings:new():get('books',{}).MP_WXS_990081)
    assert(stored.progress==.45 and same(stored.pending_upload_position,{offset=23}),'recovery changed container state')
end
local function verify(entry)
    choose(entry.location)
    local value=open(entry.path)
    assert(same(projection(value.annotation.annotations),entry.annotations),'recovered notes or bookmarks changed')
    assert(value.doc_settings:readSetting('last_xpointer')==entry.xpointer,'recovered position changed')
    assert(value.document:isXPointerInCurrentPage(entry.xpointer),'recovered position is not visible')
    local text=value.document:getTextFromXPointer('/html/body') or value.document:getTextFromXPointer('/body')
    assert(text and text:find(entry.word,1,true) and not text:find(entry.word=='OLDTEXT' and 'NEWTEXT' or 'OLDTEXT',1,true),
        'recovered ReaderUI used another version body cache')
    if entry.resource_artifact then
        local fixture=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))..'mp_title_record_images.lua'
        dofile(fixture)(entry,value)
    end
    UIManager:forceRePaint();close(value)
    local data=Doc:open(entry.path)
    assert(same(projection(data:readSetting('annotations')),entry.annotations))
    assert(data:readSetting('last_xpointer')==entry.xpointer)
    local _,location=Doc:findSidecarFile(entry.path);assert(location==entry.location)
    assert(Crypto.sha256_hex(read(entry.path))==entry.body_sha256,'recovery modified published HTML')
    if entry.archive_path then assert(Crypto.sha256_hex(read(entry.archive_path))==entry.archive_sha256,'snapshot archive changed') end
    if entry.record_id then
        local store=assert(require('weread.lib.mp_records_db').new(settings,require('weread.lib.library_db'):new(settings):accountKey()))
        assert(Crypto.sha256_hex(assert(store:get(entry.article_key,entry.record_id)))==entry.record_sha256,'saved raw snapshot changed')
        assert(data:readSetting('partial_md5_checksum')==util.partialMD5(entry.path),'recovery reused the old checksum')
    end
end
local old_location=G_reader_settings:readSetting('document_metadata_folder','doc')
local manifest_path=evidence..(title and '/mp-title-fixtures.json' or product and '/mp-records-fixtures.json' or '/mp-legacy-fixtures.json')
local report={result='UNVERIFIED',synthetic_only=true,actual_reader=true,actual_location_menu=true,
    automatic_product_recovery=false,product_recovery_entry_implemented=product,account_requests=0,account_data_writes=0}
if arg[1]=='recover' or arg[1]=='product' or arg[1]=='title' then
    local book={book_id='MP_WXS_990081',title='合成旧共享阅读记录',cache_dir=settings.data_dir..'/legacy-metadata',
        progress=.45,pending_upload_position={offset=23}}
    local article={reviewId='legacy-record-fixture',title='旧文章的记录恢复'};book.mp_articles={article}
    settings:set('books',{[book.book_id]=book});settings:flush()
    local key=assert(Identity.key(book,article));local first=assert(Identity.prepare(book.cache_dir,key))
    local parent=first:match('^(.*)/[^/]+$')
    local sources={{path=first,word='OLDTEXT',role='backup',page=2},
        {path=parent..'/article-1111111111111111.html',word='NEWTEXT',role='primary',page=4}}
    for _,entry in ipairs(sources) do
        local body='<p>'..string.rep('A',6000)..entry.word..string.rep('B',24000)..'</p>'
        write(entry.path,Content.render_mp_article_html(article,body,key))
        entry.body_sha256=Crypto.sha256_hex(read(entry.path))
    end
    assert(util.partialMD5(sources[1].path)==util.partialMD5(sources[2].path),'legacy hash collision not reproduced')
    choose('hash');Doc.setIsHashLocationEnabled(true)
    local shared
    for index,entry in ipairs(sources) do
        local value=open(entry.path)
        if index==2 then
            assert(same(projection(value.annotation.annotations),sources[1].annotations),'collision did not inherit earlier notes')
            value.annotation.annotations={}
        end
        value.rolling:onGotoPage(entry.page);value.bookmark:onToggleBookmark()
        local selected=assert(value.document:getTextFromPositions({x=1,y=1},
            {x=Device.screen:getWidth()-2,y=Device.screen:getHeight()-2},true))
        value.annotation:addItem{page=selected.pos0,pos0=selected.pos0,pos1=selected.pos1,text=selected.text,
            note='合成旧笔记 '..entry.role,drawer='lighten',datetime='2026-11-09 18:00:00'}
        entry.annotations=projection(value.annotation.annotations);assert(#entry.annotations==2)
        close(value)
        local data=Doc:open(entry.path);entry.xpointer=assert(data:readSetting('last_xpointer'))
        shared=assert(Doc:findSidecarFile(entry.path))
        if index==1 then assert(lfs.touch(shared,os.time()-120,os.time()-120)) end
    end
    assert(sources[1].xpointer~=sources[2].xpointer)
    local originals={primary=read(shared),backup=read(shared..'.old')}
    local entries={}
    if product then
        local fixture=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
            ..(title and 'mp_title_record_recovery.lua' or 'mp_record_recovery_smoke.lua')
        local result=dofile(fixture){home=home,evidence=evidence,settings=settings,book=book,article=article,sources=sources,
            shared=shared,originals=originals,key=key,open=open,close=close,choose=choose,verify=verify,projection=projection,
            same=same,read=read,count_external_open=function(count) opens=opens+count end}
        entries=result.entries;report.product_cases=result.cases
        report.native_confirmation=true;report.expected_reader_opens=result.expected_reader_opens
    else
    for _,location in ipairs(locations) do
        choose(location)
        for index,source in ipairs(sources) do
            -- The user must choose a snapshot and body. This fixture names that
            -- choice explicitly; doc_path or timestamps do not infer ownership.
            local archive=evidence..'/legacy-'..location..'-'..source.role..'.lua'
            write(archive,originals[source.role])
            local nonce=Crypto.sha256_hex('legacy-recovery-fixture-'..location..index):sub(1,16)
            local path=parent..'/article-'..nonce..'.html'
            local html=read(source.path):gsub('<head>',
                '<head>\n<meta name="weread-mp-cache-revision" content="'..nonce..'"/>',1)
            write(path,html)
            assert(Versions.contains(book.cache_dir,key,path))
            assert(util.partialMD5(path)~=util.partialMD5(source.path),'recovered copy still shares legacy hash')
            assert(not Doc:hasSidecarFile(path),'recovery target already has records')
            local selected=Doc.openSettingsFile(archive)
            assert(same(projection(selected:readSetting('annotations')),source.annotations))
            assert(selected:readSetting('last_xpointer')==source.xpointer)
            local target=Doc:open(path);selected.data.doc_path=path;target.data=selected.data
            assert(target:flush())
            local entry={path=path,location=location,source_role=source.role,annotations=source.annotations,
                xpointer=source.xpointer,body_sha256=Crypto.sha256_hex(html),word=source.word,
                archive_path=archive,archive_sha256=Crypto.sha256_hex(originals[source.role])}
            verify(entry);entries[#entries+1]=entry
            assert(read(shared)==originals.primary and read(shared..'.old')==originals.backup,
                'explicit recovery changed shared source records')
        end
    end
    -- Destructive control: stock migration of the original file loses both
    -- shared candidates. Independently recovered copies must still reopen.
    choose('doc')
    local value=open(first)
    assert(value.doc_settings:readSetting('last_xpointer')==sources[2].xpointer,'control did not select wrong position')
    assert(same(projection(value.annotation.annotations),sources[2].annotations),'control did not inherit other version notes')
    close(value)
    assert(not lfs.attributes(shared) and not lfs.attributes(shared..'.old'),'control did not remove shared records')
    assert(Doc:open(sources[2].path):readSetting('annotations')==nil,'control did not lose other version records')
    for _,source in ipairs(sources) do assert(Crypto.sha256_hex(read(source.path))==source.body_sha256) end
    for _,entry in ipairs(entries) do verify(entry) end
    write(manifest_path,json.encode(entries))
    report.sampled_hash_collision=true;report.shared_primary_backup_distinct=true
    report.stock_migration_deletes_shared_candidates=true;report.original_html_unchanged=true
    report.chosen_snapshots_restored=true;report.recovered_after_source_candidates_removed=true
    report.recovered_versions=#entries;report.source_snapshots=2
    end
    if product then write(manifest_path,json.encode(entries));report.recovered_versions=#entries end
else
    assert(arg[1]=='reopen' or arg[1]=='product-reopen' or arg[1]=='title-reopen','expected recovery or reopen mode')
    local entries=json.decode(read(manifest_path));assert(#entries==(title and 5 or product and 8 or 6))
    for _,entry in ipairs(entries) do verify(entry) end
    if title then
        local descriptor=json.decode(read(evidence..'/mp-title-export.json'))
        local value=Reader:new{dimen=Device.screen:getSize(),document=require('document/documentregistry'):openDocument(descriptor.path)}
        UIManager:show(value);opens=opens+1
        assert(value.document:getPageCount()>=6)
        local artifact={};for name,item in pairs(entries[4]) do artifact[name]=item end
        artifact.exported,artifact.path,artifact.xpointer=true,descriptor.path,value.document:getXPointer();artifact.preview_png=nil
        dofile(assert(debug.getinfo(1,'S').source:match('^@(.*/)'))..'mp_title_record_images.lua')(artifact,value)
        close(value)
    end
    report.fresh_process=true;report.recovered_versions=#entries
end
choose(old_location);G_reader_settings:flush()
report.reader_opens=opens;assert(opens==(title and (arg[1]=='title' and report.expected_reader_opens or 6)
    or product and (arg[1]=='product' and report.expected_reader_opens or 8) or arg[1]=='recover' and 15 or 6))
report.result='PASS';write(evidence..(title and '/mp-title-' or product and '/mp-records-' or '/mp-legacy-')..arg[1]..'.json',json.encode(report))
print('PASS: native reading record '..arg[1]..', '..report.recovered_versions..' independent copies')

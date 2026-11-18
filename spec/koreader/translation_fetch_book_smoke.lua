-- Actual ReaderUI with a synthetic six-chapter book and mock HTTP service.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
if os.getenv('WEREAD_TRANSLATION_HASH_STORAGE')=='1' then
    G_reader_settings:saveSetting('document_metadata_folder','hash')
    require('docsettings').setIsHashLocationEnabled(true)
elseif os.getenv('WEREAD_TRANSLATION_DIR_STORAGE')=='1' then
    G_reader_settings:saveSetting('document_metadata_folder','dir')
    require('docsettings').setIsHashLocationEnabled(true)
end
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UI=require('ui/uimanager')
local Reader=require('apps/reader/readerui')
local Content=require('weread.lib.content')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Fetch=require('weread.ui.translation_fetch')
local tr=require('weread.lib.i18n').tr
local settings=require('weread.lib.settings'):new()
local offline=os.getenv('WEREAD_TRANSLATION_FETCH_OFFLINE')=='1'
local annotations_test=os.getenv('WEREAD_TRANSLATION_ANNOTATIONS')=='1'
local function bytes(path) local f=assert(io.open(path,'rb'));local raw=f:read('*a');f:close();return raw end
local state_path=evidence..'/translation-book-state.json'
local path,copy,original,bookmark,original_note_time
if offline then
    local state=require('json').decode(bytes(state_path));path,copy,bookmark=state.original,state.copy,state.bookmark
    original=bytes(path);assert(require('weread.lib.crypto').sha256_hex(original)==state.original_sha256)
else
    local chapters,bodies,sources={},{},{}
    local book={book_id='900001',bookVersion=7,title='整书译文原生验证',author='Synthetic'}
    for uid=1,6 do
        local chapter={chapterUid=uid,chapterIdx=uid,title='Chapter '..uid,wordCount=1800}
        local paragraphs={}
        for i=1,12 do paragraphs[#paragraphs+1]='<p>Original chapter '..uid..' paragraph '..(annotations_test and uid==3 and i==12 and 11 or i)..'. '
            ..(annotations_test and uid==4 and i==8 and '😀 &amp; <em>跨标签文字</em> ' or '')
            ..string.rep('Unique native translation refresh text. ',8)..'</p>' end
        local raw='<html><body><h1>Chapter '..uid..'</h1>'..table.concat(paragraphs)..'</body></html>'
        chapters[uid],bodies[tostring(uid)],sources[tostring(uid)]=chapter,raw,assert(Source.capture(book,chapter,raw,'web_xhtml'))
    end
    book.chapters=chapters
    path=Content.save_book_epub(settings,book,chapters,bodies,'original',nil,nil,nil,Identity.capture(book),sources)
    book.cached_full_book=path;book.cached_file=path;settings:set('books',{['900001']=book})
    settings:set('cookies',{wr_vid='900000',wr_skey='synthetic-cookie'});settings:set('account',{user_vid='900000'})
    settings:set('sync',{pull_on_open=false,upload_on_close=false});settings:set('read_report',{enabled=false})
    local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.show_annotations=false;cache.download_book_images=false
    settings:set('cache',cache);settings:flush();original=bytes(path)
end
local socket=require('socket')
local reader,plugin,doc
UI:setRunForeverMode();UI:setInputTimeout(0)
local function pump(check,seconds)
    local deadline=socket.gettime()+(seconds or 90)
    repeat UI:handleInput();if check() then return end;assert(socket.gettime()<deadline,'translation book runtime deadline');socket.sleep(.01) until false
end
local function clean() while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end end
local function adopt(value) reader=value;plugin=assert(reader.weread);doc=reader.document;clean() end
local function open(file)
    local value=Reader:new{dimen=Device.screen:getSize(),document=require('document/documentregistry'):openDocument(file)}
    UI:show(value);adopt(value)
end
local function chapter(index)
    local xp='/body/DocFragment['..index..']/body/p[8]'
    assert(doc:isXPointerInDocument(xp),'chapter target unavailable')
    reader.rolling:onGotoXPointer(xp);plugin:onPageUpdate()
    local location=require('weread.lib.source_context').location(doc,'page')
    local member=require('weread.lib.source_dom').member(doc,location.xpointer)
    local source=assert(Source.document_metadata(doc,'900001',nil,member.render_path))
    assert(source.chapter_uid==tostring(index),'wrong current chapter')
end
local function choose(label)
    plugin:showReadingLanguage();pump(function() return not plugin.translation_job end)
    local menu=assert(plugin._translation_menu);local entry
    for _,item in ipairs(menu.item_table) do if item.text==tr(label) then entry=item end end
    assert(entry,'translation menu entry missing');menu:onMenuSelect(entry)
end
open(path)
if offline then
    assert(reader.annotation.annotations[1].page==bookmark,'original bookmark lost on restart')
    chapter(4);plugin.client.request=function() error('offline process attempted HTTP') end
    local old=reader;choose('Open saved translated copy')
    pump(function() return Reader.instance and Reader.instance~=old and Reader.instance.document.file==copy end)
    adopt(Reader.instance)
    local location=require('weread.lib.source_context').location(doc,'page')
    local member=require('weread.lib.source_dom').member(doc,location.xpointer)
    assert(assert(Source.document_metadata(doc,'900001',nil,member.render_path)).chapter_uid=='4','offline copy reopened wrong chapter')
    assert(plugin._translation_mode=='bilingual' and bytes(path)==original,'offline copy changed original or lost mode')
    if annotations_test then
        assert(#reader.annotation.annotations==3,'offline copy lost or duplicated annotations')
        local notes={};for _,item in ipairs(reader.annotation.annotations) do if item.note then notes[item.note]=true end end
        assert(notes['Existing target note'] and notes['Original chapter four note'] and not notes['Ambiguous note'],
            'offline copied annotations changed or included ambiguous text')
    end
    local out=assert(io.open(evidence..'/translation-book-offline.json','w'))
    out:write(require('json').encode{result='PASS',new_process=true,correct_chapter=true,network_requests=0});out:close()
    reader:onClose(false);return
end
chapter(2);reader.bookmark:onToggleBookmark();bookmark=assert(reader.annotation.annotations[1]).page
if annotations_test then
    local function add_note(index,paragraph,note)
        chapter(index)
        local first='/body/DocFragment['..index..']/body/p['..paragraph..']/text().10'
        local last='/body/DocFragment['..index..']/body/p['..paragraph..']/'
            ..(index==4 and 'em[1]/text().3' or 'text().40')
        assert(doc:isXPointerInDocument(first) and doc:isXPointerInDocument(last))
        local quote=assert(doc:getTextFromXPointers(first,last));doc:clearSelection()
        reader.annotation:addItem{page=first,pos0=first,pos1=last,text=quote,note=note,drawer='underscore',color='yellow'}
    end
    add_note(2,8,'Original chapter two note')
    add_note(3,11,'Ambiguous note')
    add_note(4,8,'Original chapter four note')
    for _,item in ipairs(reader.annotation.annotations) do
        if item.note=='Original chapter four note' then original_note_time=item.datetime end
    end
    assert(original_note_time,'source note timestamp missing')
    chapter(2)
end
choose('Download existing translations for full book')
assert(plugin.translation_fetch_job and plugin.translation_fetch_worker.job,'full book did not start in worker')
local heartbeat=false;UI:scheduleIn(.05,function() heartbeat=true end)
pump(function() return not plugin.translation_fetch_job and heartbeat end)
local dialog=assert(plugin._translation_fetch_result,'full book copy not published')
local record=assert(reader.doc_settings:readSetting('weread_translation_copies').__full)
copy=record.path
assert(copy~=path and bytes(path)==original and reader.annotation.annotations[1].page==bookmark,'original file or bookmark changed')
local isolation=require('weread.lib.translation_record_isolation')
assert(isolation.check(path,copy),'translated copy does not have independent record locations')
assert(bytes(copy):sub(1,1024):find('META-INF/weread-translation-copy-id.txt',1,true),'copy identity is outside the sampled hash region')
local collision=path..'.collision.epub'
local identical=assert(io.open(collision,'wb'));assert(identical:write(original));assert(identical:close())
assert(not isolation.check(path,collision),'identical sampled hash was accepted')
local _,owner=Fetch.saved_entry(plugin)
assert(owner and not Fetch.open_copy(plugin,owner,collision,{}),'collision opened a shared reading record')
assert(reader.document.file==path and bytes(path)==original and reader.annotation.annotations[1].page==bookmark,
    'collision check changed the original reader or bookmark')
local top=UI:getTopmostVisibleWidget()
if top and top~=dialog and top~=reader then UI:close(top) end
assert(os.remove(collision))
do
    local directory=assert(path:match('^(.*)/[^/]+$'))
    local out=require('weread.lib.notes_export_file')
    local a,b=assert(out.create(directory,'copy-nonce','epub_part')),assert(out.create(directory,'copy-nonce','epub_part'))
    local item={chapterUid=1,chapterIdx=1,title='Synthetic',wordCount=100}
    local sample={book_id='900001',bookVersion=7,title='Synthetic',cache_dir=directory}
    local text='<html><body><p>Identical original text</p><p class="wr-translation">相同译文</p></body></html>'
    local source=assert(Source.capture(sample,item,text,'web_xhtml'))
    Content.save_chapter_epub(settings,sample,item,text,nil,nil,Identity.capture(sample),source,a)
    Content.save_chapter_epub(settings,sample,item,text,nil,nil,Identity.capture(sample),source,b)
    local function nonce(file)
        local head=bytes(file):sub(1,1024);local name='META-INF/weread-translation-copy-id.txt'
        local at=assert(head:find(name,1,true))+#name
        for candidate in head:sub(at):gmatch('[a-f0-9]+') do if #candidate==64 then return candidate end end
    end
    local first,second=nonce(a.path),nonce(b.path)
    assert(first and second and first~=second,'identical copies reused their sampled nonce')
    assert(require('util').partialMD5(a.path)~=require('util').partialMD5(b.path),'identical copies share a sampled hash')
    a:abort();b:abort()
end
assert(plugin.settings:get_book('900001').cached_full_book==path,'full copy replaced the original cache')
local profile=assert(require('weread.lib.translation_archive').inspect(copy,'900001'))
assert(#profile.chapters==6 and profile.blocks==60 and record.blocks==60,'full book missed or invented translation chapters')
assert(profile.chapters[6].blocks==0,'untranslated chapter was omitted or invented')
local old=reader;dialog.ok_callback()
pump(function() return Reader.instance and Reader.instance~=old and Reader.instance.document.file==copy end)
adopt(Reader.instance)
local location=require('weread.lib.source_context').location(doc,'page')
local member=require('weread.lib.source_dom').member(doc,location.xpointer)
assert(assert(Source.document_metadata(doc,'900001',nil,member.render_path)).chapter_uid=='2','copy opened wrong chapter')
assert(plugin._translation_mode=='bilingual' and not plugin.progress_sync.verified,'copy lost bilingual mode or gained sync permission')
if annotations_test then
    local first='/body/DocFragment[2]/body/p[15]/text().10'
    local last='/body/DocFragment[2]/body/p[15]/text().40'
    local quote=assert(doc:getTextFromXPointers(first,last));doc:clearSelection()
    reader.annotation:addItem{page=first,pos0=first,pos1=last,text=quote,note='Existing target note',drawer='underscore',color='yellow'}
end
chapter(5)
reader:onClose(false);open(path)
assert(reader.annotation.annotations[1].page==bookmark and bytes(path)==original,'original bookmark or bytes changed after copy')
chapter(4);plugin.client.request=function() error('offline shortcut attempted HTTP') end
old=reader;choose(annotations_test and 'Copy local annotations to translated copy' or 'Open saved translated copy')
pump(function() return Reader.instance and Reader.instance~=old and Reader.instance.document.file==copy end)
adopt(Reader.instance)
location=require('weread.lib.source_context').location(doc,'page');member=require('weread.lib.source_dom').member(doc,location.xpointer)
assert(assert(Source.document_metadata(doc,'900001',nil,member.render_path)).chapter_uid=='4','offline shortcut opened wrong chapter')
if annotations_test then
    assert(#reader.annotation.annotations==3,'annotation copy count was incorrect')
    local notes={}
    for _,item in ipairs(reader.annotation.annotations) do
        if item.note then
            notes[item.note]=true
            assert(doc:isXPointerInDocument(item.pos0) and doc:isXPointerInDocument(item.pos1),'copied highlight pointer is invalid')
            local quoted=doc:getTextFromXPointers(item.pos0,item.pos1);doc:clearSelection()
            assert(quoted==item.text and item.drawer=='underscore' and item.color=='yellow','copied highlight text or style changed')
            if item.note=='Original chapter four note' then
                assert(item.datetime==original_note_time,'copied note timestamp changed')
                assert(quoted:find('😀',1,true) and quoted:find('&',1,true) and quoted:find('跨标签',1,true),'unicode or nested selection was not preserved')
            end
        end
    end
    assert(notes['Existing target note'] and notes['Original chapter four note'] and not notes['Original chapter two note'] and not notes['Ambiguous note'],
        'copy overwrote an existing note or included ambiguous source')
end
reader:onClose(false);open(path)
if annotations_test then
    assert(#reader.annotation.annotations==4,'original annotations were changed')
    local original_notes={};for _,item in ipairs(reader.annotation.annotations) do if item.note then original_notes[item.note]=true end end
    assert(original_notes['Original chapter two note'] and original_notes['Ambiguous note'] and original_notes['Original chapter four note'],
        'original notes changed during copy')
    chapter(4);plugin.client.request=function() error('repeat annotation copy attempted HTTP') end
    old=reader;choose('Copy local annotations to translated copy')
    pump(function() return Reader.instance and Reader.instance~=old and Reader.instance.document.file==copy end)
    adopt(Reader.instance);assert(#reader.annotation.annotations==3,'repeated copy created duplicates')
    reader:onClose(false);open(path)
end
-- A cancelled worker and a failure after two chapters must not publish a
-- partial book or replace either the original or an already accepted copy.
local accepted=bytes(copy)
assert(Fetch.start(plugin,true));local job=assert(plugin.translation_fetch_job)
local partial,pid=job.output.path,plugin.translation_fetch_worker.job.pid
plugin.busy_message:onTapClose()
assert(not plugin.translation_fetch_job and not require('libs/libkoreader-lfs').attributes(partial),'cancel retained staged book')
pump(function() return require('ffi/util').isSubProcessDone(pid) end)
local core=require('weread.lib.translation_fetch');local run=core.run_book
core.run_book=function(client,...)
    local request,reads=client.request,0
    client.request=function(self,options)
        if options.url:find('/web/book/chapter/e_0',1,true) then
            reads=reads+1;if reads==3 then error('synthetic chapter failure',0) end
        end
        return request(self,options)
    end
    local ok=pcall(run,client,...)
    assert(not ok and reads==3,'third-chapter failure was not observed')
    return {ok=false,third_chapter_failure=true}
end
local worker=plugin.translation_fetch_worker;local start=worker.start;local saw_failure=false
worker.start=function(self,task,callback) return start(self,task,function(value)
    saw_failure=type(value)=='table' and value.third_chapter_failure==true;callback(value)
end) end
assert(Fetch.start(plugin,true));partial=plugin.translation_fetch_job.output.path
pump(function() return not plugin.translation_fetch_job end)
assert(saw_failure and not require('libs/libkoreader-lfs').attributes(partial),'failed chapter left a staged book')
assert(bytes(path)==original and bytes(copy)==accepted and reader.doc_settings:readSetting('weread_translation_copies').__full.path==copy,
    'failed full-book download changed original or accepted copy')
local catalog=Content.fetch_catalog
core.run_book=function(...)
    local calls=0
    Content.fetch_catalog=function(...)
        local chapters,version=catalog(...);calls=calls+1
        if calls==2 then chapters[1].title=chapters[1].title..' changed' end
        return chapters,version
    end
    local ok,reason=pcall(run,...)
    assert(not ok and reason=='translation_fetch/catalog_changed' and calls==2,'changed catalog was accepted')
    return {ok=false,catalog_changed=true}
end
local saw_catalog=false
worker.start=function(self,task,callback) return start(self,task,function(value)
    saw_catalog=type(value)=='table' and value.catalog_changed==true;callback(value)
end) end
clean();assert(Fetch.start(plugin,true));partial=plugin.translation_fetch_job.output.path
pump(function() return not plugin.translation_fetch_job end)
assert(saw_catalog and not require('libs/libkoreader-lfs').attributes(partial),'changed catalog left a staged book')
assert(bytes(path)==original and bytes(copy)==accepted and reader.doc_settings:readSetting('weread_translation_copies').__full.path==copy,
    'changed catalog replaced original or accepted copy')
local model=require('weread.lib.translation');local analyze=model.analyze
core.run_book=function(...)
    model.analyze=function(...)
        local analyzed,reason=analyze(...)
        if analyzed then analyzed.blocks=0 end
        return analyzed,reason
    end
    local value=run(...)
    assert(value.ok==false and value.reason=='missing','book with no translations was accepted')
    return {ok=false,reason='missing',missing_verified=true}
end
local saw_missing=false
worker.start=function(self,task,callback) return start(self,task,function(value)
    saw_missing=type(value)=='table' and value.missing_verified==true;callback(value)
end) end
clean();assert(Fetch.start(plugin,true));partial=plugin.translation_fetch_job.output.path
pump(function() return not plugin.translation_fetch_job end)
assert(saw_missing and not require('libs/libkoreader-lfs').attributes(partial),'untranslated book left a staged copy')
assert(bytes(path)==original and bytes(copy)==accepted and reader.doc_settings:readSetting('weread_translation_copies').__full.path==copy,
    'untranslated book replaced original or accepted copy')
core.run_book=run;worker.start=start;clean()
local saved=assert(io.open(state_path,'w'));saved:write(require('json').encode{original=path,copy=copy,bookmark=bookmark,
    original_sha256=require('weread.lib.crypto').sha256_hex(original)});saved:close()
local out=assert(io.open(evidence..'/translation-book.json','w'));out:write(require('json').encode{result='PASS',synthetic_only=true,
    chapters=6,chapters_with_translation=5,blocks=60,original_unchanged=true,bookmark_preserved=true,
    correct_initial_and_offline_chapters=true,independent_worker=true,cancel_and_chapter_failure_cleaned=true,
    changed_catalog_cleaned=true,no_translation_cleaned=true,account_data_writes=0});out:close()
reader:onClose(false);print('PASS: native full-book translation copy, chapter navigation and offline original protection')

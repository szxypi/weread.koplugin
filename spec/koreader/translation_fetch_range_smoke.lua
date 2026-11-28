-- Native three-chapter translated copy, isolated synthetic account and HTTP.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UI,Reader=require('ui/uimanager'),require('apps/reader/readerui')
local Content,Source=require('weread.lib.content'),require('weread.lib.position_source')
local Identity,Fetch=require('weread.lib.book_file_identity'),require('weread.ui.translation_fetch')
local tr=require('weread.lib.i18n').tr
local settings=require('weread.lib.settings'):new()
local offline=os.getenv('WEREAD_TRANSLATION_FETCH_OFFLINE')=='1'
local function bytes(path) local file=assert(io.open(path,'rb'));local raw=file:read('*a');file:close();return raw end
local state_path=evidence..'/translation-range-state.json'
local path,copy,original,bookmark,saved_state
if offline then
    saved_state=require('json').decode(bytes(state_path))
    path,copy,bookmark=saved_state.original,saved_state.copy,saved_state.bookmark
    original=bytes(path);assert(require('weread.lib.crypto').sha256_hex(original)==saved_state.original_sha256)
else
    local chapters,bodies,sources={},{},{}
    local book={book_id='900001',bookVersion=7,title='分章译文验证',author='Synthetic'}
    for uid=1,6 do
        local chapter={chapterUid=uid,chapterIdx=uid,title='Chapter '..uid,wordCount=1800}
        local paragraphs={}
        for i=1,12 do paragraphs[#paragraphs+1]='<p>Original chapter '..uid..' paragraph '..i..'. '
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
local socket=require('socket');local reader,plugin,doc
UI:setRunForeverMode();UI:setInputTimeout(0)
local function pump(check)
    local deadline=socket.gettime()+90
    repeat UI:handleInput();if check() then return end;assert(socket.gettime()<deadline,'range translation deadline');socket.sleep(.01) until false
end
local function clean() while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end end
local function adopt(value) reader=value;plugin=assert(reader.weread);doc=reader.document;clean() end
local function open(file)
    local value=Reader:new{dimen=Device.screen:getSize(),document=require('document/documentregistry'):openDocument(file)}
    UI:show(value);adopt(value)
end
local function chapter(index)
    local xp='/body/DocFragment['..index..']/body/p[8]'
    assert(doc:isXPointerInDocument(xp));reader.rolling:onGotoXPointer(xp);plugin:onPageUpdate()
end
local function current_uid()
    local location=require('weread.lib.source_context').location(doc,'page')
    local member=assert(require('weread.lib.source_dom').member(doc,location.xpointer))
    return assert(Source.document_metadata(doc,'900001',nil,member.render_path)).chapter_uid
end
local function choose(label)
    plugin:showReadingLanguage();pump(function() return not plugin.translation_job end)
    local menu=assert(plugin._translation_menu)
    for _,item in ipairs(menu.item_table) do if item.text==tr(label) then menu:onMenuSelect(item);return end end
    error('translation menu entry missing: '..label)
end
open(path)
if offline then
    assert(reader.annotation.annotations[1].page==bookmark)
    local pending=require('weread.lib.translation_resume'):new(plugin.library_db,plugin.client,plugin.settings:get_auth_scope())
    assert(pending:get(saved_state.pending,'1')=='synthetic saved full-book chapter',
        'range download changed the full-book checkpoint after restart')
    chapter(4);plugin.client.request=function() error('offline range attempted HTTP') end
    local old=reader;choose('Open saved translated copy')
    pump(function() return Reader.instance and Reader.instance~=old and Reader.instance.document.file==copy end)
    adopt(Reader.instance)
    assert(current_uid()=='4' and plugin._translation_mode=='bilingual' and bytes(path)==original)
    reader:onClose(false);open(path);chapter(6)
    plugin.client.request=function() error('offline tail attempted HTTP') end
    old=reader;choose('Open saved translated copy')
    pump(function() return Reader.instance and Reader.instance~=old and Reader.instance.document.file==saved_state.tail_copy end)
    adopt(Reader.instance)
    assert(current_uid()=='6' and plugin._translation_mode=='bilingual','untranslated tail chapter was not retained')
    reader:onClose(false);print('PASS: saved range reopened offline at the matching chapter');return
end
chapter(2);reader.bookmark:onToggleBookmark();bookmark=assert(reader.annotation.annotations[1]).page
local location=require('weread.lib.source_context').location(doc,'page')
local member=assert(require('weread.lib.source_dom').member(doc,location.xpointer))
local original_source=assert(Source.document_metadata(doc,'900001',nil,member.render_path))
local pending=require('weread.lib.translation_resume'):new(plugin.library_db,plugin.client,plugin.settings:get_auth_scope())
local token=assert(pending:begin('900001',original_source.identity.file_id,{{chapterUid=1,title='Synthetic'}},7,false))
assert(pending:put(token,'1','synthetic saved full-book chapter'))
choose('Download existing translations for next chapters')
assert(plugin.translation_fetch_job and plugin.busy_message and plugin.busy_message.progress_bar)
pump(function() return not plugin.translation_fetch_job end)
local result=assert(plugin._translation_fetch_result)
local entries=assert(reader.doc_settings:readSetting('weread_translation_copies'))
local record=assert(entries.__range_2);copy=record.path
assert(entries.__range_3.path==copy and entries.__range_4.path==copy and not entries.__full and not entries.__range_5)
assert(bytes(path)==original and reader.annotation.annotations[1].page==bookmark)
local profile=assert(require('weread.lib.translation_archive').inspect(copy,'900001'))
assert(#profile.chapters==3 and profile.blocks==36 and require('weread.lib.translation_record_isolation').check(path,copy))
local old=reader;result.ok_callback()
pump(function() return Reader.instance and Reader.instance~=old and Reader.instance.document.file==copy end)
adopt(Reader.instance);assert(current_uid()=='2' and plugin._translation_mode=='bilingual')
reader:onClose(false);open(path);chapter(5)
assert(Fetch.start(plugin,'range'));pump(function() return not plugin.translation_fetch_job end)
local tail=assert(plugin._translation_fetch_result)
local updated=assert(reader.doc_settings:readSetting('weread_translation_copies'))
assert(updated.__range_5 and updated.__range_6 and updated.__range_5.path==updated.__range_6.path
    and updated.__range_5.path~=copy and updated.__range_5.blocks==12 and updated.__range_2.path==copy,
    'end-of-book range lost an untranslated chapter or replaced an earlier copy')
local tail_copy=updated.__range_5.path
tail.cancel_callback();UI:close(tail);chapter(6)
assert(Fetch.start(plugin,'range'));pump(function() return not plugin.translation_fetch_job end)
assert(not plugin._translation_fetch_result and bytes(path)==original and bytes(copy)
    and reader.doc_settings:readSetting('weread_translation_copies').__range_2.path==copy,
    'untranslated final chapter replaced a previous copy')
clean();chapter(2)
local core=require('weread.lib.translation_fetch');local original_run=core.run_book
core.run_book=function(client,...)
    local request,reads=client.request,0
    client.request=function(self,options)
        if options.url:find('/web/book/chapter/e_0',1,true) then
            reads=reads+1
            if reads==2 then options.sink('synthetic limited');return nil,429,{},'limited' end
        end
        return request(self,options)
    end
    return original_run(client,...)
end
assert(Fetch.start(plugin,'range'));local failed=assert(plugin.translation_fetch_job).output.path
core.run_book=original_run;pump(function() return not plugin.translation_fetch_job end)
assert(not plugin._translation_fetch_result and not require('libs/libkoreader-lfs').attributes(failed)
    and bytes(path)==original and reader.doc_settings:readSetting('weread_translation_copies').__range_2.path==copy,
    'failed middle chapter published or replaced a copy')
clean()
local original_catalog=Content.fetch_catalog
core.run_book=function(...)
    local calls=0
    Content.fetch_catalog=function(...)
        local chapters,version=original_catalog(...);calls=calls+1
        if calls==2 then chapters[1].title=chapters[1].title..' changed' end
        return chapters,version
    end
    local ok,why=pcall(original_run,...)
    assert(not ok and why=='translation_fetch/catalog_changed' and calls==2,
        'range accepted a change outside the selected chapters')
    return {ok=false,reason='missing',catalog_verified=true}
end
local worker=assert(plugin.translation_fetch_worker);local start=worker.start;local catalog_verified=false
worker.start=function(self,task,callback,progress)
    return start(self,task,function(value) catalog_verified=type(value)=='table' and value.catalog_verified==true;callback(value) end,progress)
end
assert(Fetch.start(plugin,'range'));failed=assert(plugin.translation_fetch_job).output.path
core.run_book=original_run;pump(function() return not plugin.translation_fetch_job end);worker.start=start
assert(catalog_verified and not require('libs/libkoreader-lfs').attributes(failed)
    and reader.doc_settings:readSetting('weread_translation_copies').__range_2.path==copy,
    'changed catalog published a range copy')
clean()
assert(Fetch.start(plugin,'range'));local job=assert(plugin.translation_fetch_job);local partial=job.output.path
Fetch.cancel(plugin);assert(not plugin.translation_fetch_job and not require('libs/libkoreader-lfs').attributes(partial))
assert(bytes(path)==original and reader.doc_settings:readSetting('weread_translation_copies').__range_2.path==copy)
assert(pending:get(token,'1')=='synthetic saved full-book chapter','range download changed the full-book checkpoint')
local out=assert(io.open(state_path,'wb'))
out:write(require('json').encode{original=path,copy=copy,bookmark=bookmark,
    original_sha256=require('weread.lib.crypto').sha256_hex(original),pending=token,tail_copy=tail_copy});out:close()
reader:onClose(false);print('PASS: bounded translated range, missing chapter and cancellation preserve the original')

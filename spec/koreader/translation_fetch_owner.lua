-- Private, read-only full ReaderUI acceptance. Never emit book text or screenshots.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local home=assert(os.getenv('KO_HOME'));local mode=assert(arg[1])
local report={result='UNVERIFIED',mode=mode,phase='input',screenshots=0,requests=0,forbidden=0,failed_line=0,
    native_reader=false,downloaded=false,bilingual=false,translated_text_visible=false,original_kept=false,
    bookmark_kept=false,cache_path_kept=false,source_exact=false,shortcut=false,credential_audit=false,workers_reaped=false}
local latest,fd,counters
local ok,reason=pcall(function()
    local raw=assert(io.stdin:read(256*1024+1));assert(#raw<=256*1024)
    local input=json.decode(raw);latest=input.cookies
    local root=home..'/plugins/weread.koplugin';package.path=root..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('screenshots disabled',0) end
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int);void *mmap(void *,unsigned long,int,int,int,long);int munmap(void *,unsigned long);')
    fd=tonumber(ffi.C.memfd_create('translation-private-auth',1));assert(fd>=0)
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.vid,name=''},cookies=input.cookies,api_key=''}
    local encoded='return '..require('dump')(auth,nil,true);local offset=0
    while offset<#encoded do local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',encoded)+offset,#encoded-offset));assert(n>0);offset=offset+n end
    local Settings=require('weread.lib.settings');local new=Settings.new
    function Settings:new()
        local value=new(self);assert(not value.mock_endpoint)
        if input.mock_port then
            assert(input.vid=='900000' and input.book_id=='900001' and input.cookies.wr_skey=='mock_key')
            value.mock_endpoint='http://127.0.0.1:'..input.mock_port
        end
        local flush=value.store.flush
        value.store.flush=function(store,...)
            local held={}
            for _,key in ipairs({'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for key,item in pairs(held) do store.data[key]=item end
            if held.cookies then latest=held.cookies end
            assert(result[1]);return unpack(result,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,key=='cookies' and latest or item) end
        value.settings_file='/proc/self/fd/'..fd
        value:set('sync',{pull_on_open=false,upload_on_close=false,upload_interval_minutes=0})
        value:set('read_report',{enabled=false})
        local cache=value:get('cache');cache.download_book_images=false;cache.show_annotations=false
        cache.auto_prefetch_next_chapter=false;cache.download_underlines_and_thoughts=false;value:set('cache',cache);value:flush()
        return value
    end
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local Client=require('weread.lib.client');local request=Client.request
    local Protocol=require('weread.lib.protocol')
    function Client:request(options)
        local method=options.method or (options.body and 'POST' or 'GET');local allowed=false
        if mode=='live' then
            allowed=method=='GET' and not options.body and (options.url==Protocol.reader_url(input.book_id) or options.url==Protocol.reader_url(input.book_id,input.chapter_uid))
            if method=='POST' then
                local parsed,body=pcall(self.json_decode,self,options.body or '')
                if parsed and options.url=='https://weread.qq.com/web/book/chapterInfos' then
                    allowed=type(body.bookIds)=='table' and #body.bookIds==1 and body.bookIds[1]==input.book_id
                    for key in pairs(body) do if key~='bookIds' then allowed=false end end
                elseif parsed and options.url:match('^https://weread%.qq%.com/web/book/chapter/e_[0-3]$') then
                    allowed=body.b==Protocol.e(input.book_id) and body.c==Protocol.e(input.chapter_uid) and body.sc==1
                end
            end
        end
        if not allowed then counters[1]=counters[1]+1;error('translation acceptance request rejected',0) end
        counters[0]=counters[0]+1;assert(counters[0]<=32)
        options.sensitive=true;options.diagnostic_api='translation_acceptance'
        return request(self,options)
    end
    local Common=require('weread.ui.common')
    Common.isNetworkOnline,Common.isNetworkConnected=function() return mode=='live' end,function() return mode=='live' end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local Reader=require('apps/reader/readerui');local Content=require('weread.lib.content')
    local Source=require('weread.lib.position_source');local Identity=require('weread.lib.book_file_identity')
    local Crypto=require('weread.lib.crypto');local Fetch=require('weread.ui.translation_fetch')
    local settings=Settings:new();local state_path=home..'/translation-state.json'
    local function bytes(path) local f=assert(io.open(path,'rb'));local value=f:read('*a');f:close();return value end
    local original,copy,bookmark,before
    report.phase='prepare'
    if mode=='live' then
        local book={book_id=input.book_id,title=input.title,author=input.author}
        local client=Fetch and require('weread.lib.translation_fetch').client(Client:new(settings),book,input.chapter_uid)
        Content.ensure_reader_state(client,book)
        local chapters,version=Content.fetch_catalog(client,book);local selected
        for _,chapter in ipairs(chapters) do if tostring(chapter.chapterUid)==input.chapter_uid then assert(not selected);selected=chapter end end
        assert(selected and Crypto.sha256_hex(input.source)==input.source_sha256)
        book.bookVersion=version
        local source=assert(Source.capture(book,selected,input.source,'web_xhtml'))
        original=Content.save_chapter_epub(settings,book,selected,input.source,nil,nil,Identity.capture(book),source)
        book.cached_chapters={[input.chapter_uid]=original}
        assert(Content.save_catalog_cache(client,settings,book,chapters))
        settings:set('books',{[input.book_id]=require('weread.lib.book_store').without_reading_state(book)});settings:flush()
        before=Crypto.sha256_hex(bytes(original))
    else
        local state=json.decode(bytes(state_path));original,copy,bookmark,before=state.original,state.copy,state.bookmark,state.sha256
    end
    report.phase='reader'
    local reader=Reader:new{dimen=Device.screen:getSize(),document=require('document/documentregistry'):openDocument(original)}
    UI:show(reader);local plugin=assert(reader.weread);local document
    local socket=require('socket')
    local function pump(test)
        local deadline=socket.gettime()+70
        repeat UI:handleInput();if test() then return end;assert(socket.gettime()<deadline,'translation acceptance deadline');socket.sleep(.01) until false
    end
    local function clear() while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end end
    clear();assert(tostring(plugin:detectWeReadBook())==input.book_id);report.native_reader=true
    if mode=='live' then reader.bookmark:onToggleBookmark();bookmark=assert(reader.annotation.annotations[1]).page
    else assert(reader.annotation.annotations[1].page==bookmark) end
    plugin:showReadingLanguage();pump(function() return not plugin.translation_job end)
    local menu=assert(plugin._translation_menu);local entry
    local label=require('weread.lib.i18n').tr(mode=='live' and 'Download existing translation' or 'Open saved translated copy')
    for _,item in ipairs(menu.item_table) do if item.text==label then entry=item end end
    assert(entry);report.phase='download';menu:onMenuSelect(entry)
    if mode=='live' then
        assert(plugin.translation_fetch_job and plugin.translation_fetch_worker.job)
        pump(function() return not plugin.translation_fetch_job end)
        local dialog=assert(plugin._translation_fetch_result)
        local saved=assert(reader.doc_settings:readSetting('weread_translation_copies')[input.chapter_uid])
        -- Provenance is content-derived: an unchanged source may correctly
        -- retain its file_id. The new physical file must still be distinct.
        assert(saved.blocks==input.blocks and #saved.file_id==64 and saved.path~=original)
        local fs=require('libs/libkoreader-lfs');local old_stat,new_stat=assert(fs.symlinkattributes(original)),assert(fs.symlinkattributes(saved.path))
        assert(old_stat.ino~=new_stat.ino or old_stat.dev~=new_stat.dev)
        copy=saved.path
        assert(Crypto.sha256_hex(bytes(original))==before and reader.annotation.annotations[1].page==bookmark)
        report.downloaded=true;dialog.ok_callback()
    else report.downloaded=true end
    report.phase='copy'
    pump(function() return Reader.instance and Reader.instance~=reader and Reader.instance.document.file==copy end)
    reader=Reader.instance;plugin=assert(reader.weread);document=reader.document;clear()
    assert(plugin._translation_mode=='bilingual' and not plugin.progress_sync.verified);report.bilingual=true
    local metadata=assert(Source.document_metadata(document,input.book_id,input.chapter_uid))
    assert(metadata.record.raw_sha256==input.source_sha256);report.source_exact=true
    local profile=assert(require('weread.lib.translation_archive').inspect(copy,input.book_id));assert(profile.blocks==input.blocks)
    local pair=assert(profile.chapters[1].pairs[1]);local target='/body/DocFragment[1]'..pair.translation_path
    reader.rolling:onGotoXPointer(target)
    local normalized=document:getNormalizedXPointer(target)
    local char=document:getNextVisibleChar(target)
    assert(type(char)=='string' and document:getNormalizedXPointer(char):sub(1,#normalized)==normalized)
    report.translated_text_visible=true
    assert(plugin.settings:get_book(input.book_id).cached_chapters[input.chapter_uid]==original);report.cache_path_kept=true
    assert(Crypto.sha256_hex(bytes(original))==before);report.original_kept=true;report.bookmark_kept=true;report.shortcut=true
    reader:onClose(false)
    if mode=='live' then
        local f=assert(io.open(state_path,'wb'));f:write(json.encode{original=original,copy=copy,bookmark=bookmark,sha256=before});f:close()
    end
    local status=ffi.new('int[1]');pump(function()
        local child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG))
        while child>0 do child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG)) end
        return child<0 and ffi.errno()==10
    end);report.workers_reaped=true
    report.phase='audit'
    local secrets={}
    for _,cookies in ipairs({input.cookies,latest}) do for key,value in pairs(cookies) do if key~='wr_vid' and #value>=8 then secrets[#secrets+1]=value end end end
    local lfs=require('libs/libkoreader-lfs')
    local function audit(path)
        for name in lfs.dir(path) do if name~='.' and name~='..' and not (path==home and name=='plugins') then
            local file=path..'/'..name;local info=assert(lfs.symlinkattributes(file))
            if info.mode=='directory' then audit(file) else assert(info.mode=='file' and info.size<16*1024*1024)
                local value=bytes(file);for _,secret in ipairs(secrets) do assert(not value:find(secret,1,true),'credential file audit failed') end
            end
        end end
    end
    audit(home);report.credential_audit=true
    report.requests,report.forbidden=tonumber(counters[0]),tonumber(counters[1])
    assert(report.forbidden==0 and (mode=='live' and report.requests>0 or mode=='reopen' and report.requests==0))
    report.phase,report.result='complete','PASS'
end)
if not ok then report.failed_line=tonumber(tostring(reason):match('translation_fetch_owner%.lua:(%d+):')) or 0 end
if counters then report.requests,report.forbidden=tonumber(counters[0]),tonumber(counters[1]);ffi.C.munmap(counters,4096) end
if fd then ffi.C.close(fd) end
io.stdout:write('\nWEREAD_TRANSLATION_OWNER='..json.encode{report=report,cookies=latest or {}}..'\n')
os.exit(ok and 0 or 1)

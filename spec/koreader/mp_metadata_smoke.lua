-- Real DocSettings in all supported locations; synthetic local bodies only.
return function(plugin,count,_flush,home)
    local Doc=require('docsettings')
    local Content=require('weread.lib.content')
    local Identity=require('weread.lib.mp_cache_identity')
    local Stage=require('weread.lib.mp_download_stage')
    local Download=require('weread.lib.mp_download')
    local Versions=require('weread.lib.mp_cache_versions')
    local Cleanup=require('weread.lib.mp_cache_cleanup')
    local Recovery=require('weread.lib.mp_download_recovery')
    local Actions=require('weread.ui.mp_article_actions')
    local UIManager=require('ui/uimanager')
    local util=require('util')
    local settings,client=plugin.settings,plugin.client
    local mode=G_reader_settings:readSetting('document_metadata_folder')
    local hash_enabled=Doc.isHashLocationEnabled()
    local cache=settings:get('cache',{});local old_open=plugin.openFile;local opened
    local options={};for key,value in pairs(cache) do options[key]=value end
    options.download_mp_images=false;settings:set('cache',options);settings:flush()
    local requests=count('/web/mp/content')+count('/web/mp/articles')+count('/api/agent/gateway')
    local writes,renewals=count('/web/book/read'),count('/web/login/renewal')
    local function read(path) local f=assert(io.open(path,'rb'));local raw=f:read('*a');f:close();return raw end
    local function write(path,raw) local f=assert(io.open(path,'wb'));assert(f:write(raw));f:close() end
    local function body(word) return '<p>'..string.rep('A',6000)..word..string.rep('B',24000)..'</p>' end
    local report={result='PASS',synthetic_only=true,modes={},account_reads=0,account_data_writes=0,credential_renewals=0}
    -- Control: a real changed body beyond the engine's sampled byte ranges.
    local proof_key=assert(Identity.key({book_id='MP_WXS_900071'},{reviewId='proof'}))
    local first=Content.render_mp_article_html({title='合成哈希对照'},body('OLDTEXT'),proof_key)
    local second=Content.render_mp_article_html({title='合成哈希对照'},body('NEWTEXT'),proof_key)
    local a,b=settings.data_dir..'/hash-proof-old.html',settings.data_dir..'/hash-proof-new.html'
    write(a,first);write(b,second)
    assert(first~=second and #first==#second and util.partialMD5(a)==util.partialMD5(b),'control did not reproduce sampled-hash collision')
    report.unstamped_changed_body_same_sample_hash=true
    for _,invalid in ipairs({'short','0123456789ABCDEF','0123456789abcdef0','"><script>bad</script>'}) do
        assert(not pcall(Content.render_mp_article_html,{title='Test'},'<p>Text</p>',proof_key,invalid),'renderer accepted invalid revision')
    end
    report.invalid_revision_rejected=true
    for index,location in ipairs({'doc','dir','hash'}) do
        G_reader_settings:saveSetting('document_metadata_folder',location);Doc.setIsHashLocationEnabled(location=='hash')
        local book={book_id='MP_WXS_'..(900071+index),title='合成保存方式 '..location,
            cache_dir=settings.data_dir..'/mp-metadata-'..location,progress=.45,pending_upload_position={offset=23}}
        local article={reviewId='metadata-fixture',title='文章版本与笔记'};book.mp_articles={article}
        local books=settings:get('books',{});books[book.book_id]=book;settings:set('books',books);settings:flush()
        local key=assert(Identity.key(book,article));local calls=0
        local function download(raw)
            local input=assert(Download.capture(settings,book,article))
            local stage=assert(Stage.create(book.cache_dir,key,{preserve=calls>0}))
            local transport={request=function(_self,request)
                assert(request.method=='GET' and request.diagnostic_api=='mp_read','metadata test requested an unexpected API')
                calls=calls+1;assert(request.sink('<div id="js_content">'..raw..'</div>'));return nil,200
            end}
            local receipt=Download.write(transport,input,stage,{missing='Unavailable'})
            assert(receipt.images==0 and receipt.missing==0,'image-free fixture changed')
            local path=assert(stage:commit(receipt));local html=read(path)
            local revision=assert(stage.version_name:match('^article%-([a-f0-9]+)%.html$'))
            assert(html:sub(1,1024):find('<meta name="weread-mp-cache-revision" content="'..revision..'"/>',1,true),'revision outside first hash sample')
            return path,html
        end
        local function notes(path,text)
            local data=Doc:open(path)
            assert(not data:readSetting('last_xpointer') and not data:readSetting('annotations'),'new cache inherited old coordinates or notes: '..location)
            data:saveSetting('last_xpointer','/body/p[1]/text().10')
            data:saveSetting('annotations',{{text=text,note='独立的合成笔记',pos0='/body/p[1]',pos1='/body/p[1]'}})
            local dir=assert(data:flush());local file=dir..'/'..data.sidecar_filename
            local _,found=Doc:findSidecarFile(path)
            assert(found==location,'DocSettings did not actually use selected location')
            return file,read(file)
        end
        local old,old_body=download(body('OLDTEXT'));local old_notes,old_data=notes(old,'旧版划线')
        local new,new_body=download(body('NEWTEXT'));local new_notes,new_data=notes(new,'新版划线')
        local same,same_body=download(body('NEWTEXT'));local same_notes,same_data=notes(same,'再次下载独立划线')
        assert(old~=new and new~=same and old_notes~=new_notes and new_notes~=same_notes,'immutable paths or metadata collided')
        assert(util.partialMD5(old)~=util.partialMD5(new) and util.partialMD5(new)~=util.partialMD5(same),'revision failed to isolate sampled hash')
        assert(read(old)==old_body and read(new)==new_body and read(same)==same_body
            and read(old_notes)==old_data and read(new_notes)==new_data and read(same_notes)==same_data,'download modified earlier body or notes')
        assert(Doc:open(old):readSetting('annotations')[1].text=='旧版划线'
            and Doc:open(new):readSetting('annotations')[1].text=='新版划线','reopening mixed revision notes')
        plugin.openFile=function(_self,path) opened=path end
        plugin:closeWeReadUI();assert(Actions.history(plugin,book,article));local menu=assert(plugin._mp_versions_menu)
        assert(#menu.item_table==3 and Versions.resolve(book.cache_dir,key)==same,'saved version list lost a revision')
        local seen={}
        for _,row in ipairs(menu.item_table) do
            opened=nil;row.callback()
            assert(opened==old or opened==new or opened==same,'native history did not open immutable version')
            assert(not seen[opened],'native history repeated a different version');seen[opened]=true
        end
        assert(seen[old] and seen[new] and seen[same],'native history omitted a revision')
        UIManager:forceRePaint();require('device').screen:shot(home..'/../evidence/mp-metadata-'..location..'.png')
        plugin:closeWeReadUI()
        -- Render changed text through the real engine; the head marker is passive.
        for _,entry in ipairs({{path=old,text='OLDTEXT'},{path=new,text='NEWTEXT'}}) do
            local doc=assert(require('document/documentregistry'):openDocument(entry.path))
            assert(doc:loadDocument());doc:render()
            assert((doc:getTextFromXPointer('/html/body') or doc:getTextFromXPointer('/body')):find(entry.text,1,true),'native engine lost changed body')
            doc:close()
        end
        -- Explicitly remove the old body; all three metadata files stay intact.
        local opened_file=plugin.ui.document and plugin.ui.document.file
        local plan=Cleanup.check(Cleanup.scan(book.cache_dir,key,opened_file),book.cache_dir,key,opened_file)
        local gate=assert(Cleanup.acquire(book.cache_dir,key))
        local fresh=Cleanup.check(Cleanup.scan(book.cache_dir,key,opened_file,gate.info),book.cache_dir,key,opened_file)
        local job=Cleanup.begin(plan,old:match('[^/]+$'),gate,fresh)
        local good,why repeat good,why=Cleanup.step(job);assert(good) until why=='done'
        gate:release()
        assert(not require('libs/libkoreader-lfs').attributes(old) and read(old_notes)==old_data
            and read(new_notes)==new_data and read(same_notes)==same_data,'old body cleanup touched metadata')
        local stage=assert(Stage.create(book.cache_dir,key,{preserve=true}));stage:close();stage:release_lease(false)
        local before=Recovery.check(Recovery.scan(book.cache_dir,key,opened_file),book.cache_dir,key,opened_file)
        gate=assert(Cleanup.acquire(book.cache_dir,key))
        fresh=Recovery.check(Recovery.scan(book.cache_dir,key,opened_file),book.cache_dir,key,opened_file)
        local nonce=assert(stage.version_name:match('^article%-([a-f0-9]+)%.html$'))
        job=Recovery.begin(before,fresh,nonce,'clean',gate)
        repeat good,why=Recovery.step(job);assert(good) until why=='done'
        Recovery.release(job);gate:release()
        assert(read(old_notes)==old_data and read(new_notes)==new_data and read(same_notes)==same_data,'temporary repair touched metadata')
        local latest=settings:get('books',{})[book.book_id]
        assert(latest.progress==.45 and latest.pending_upload_position.offset==23 and calls==3,'metadata workflow changed reading state')
        report.modes[#report.modes+1]={location=location,actual_docsettings_location=true,changed_body_isolated=true,
            identical_redownload_isolated=true,old_notes_readback=true,metadata_bytes_preserved=true,
            native_history_three_versions=true,cre_changed_bodies=true,explicit_body_cleanup_keeps_metadata=true,
            interrupted_cleanup_keeps_metadata=true,progress_pending_preserved=true,synthetic_transport_calls=3}
    end
    plugin.openFile=old_open;plugin:closeWeReadUI();settings:set('cache',cache);settings:flush()
    if mode==nil then G_reader_settings:delSetting('document_metadata_folder') else G_reader_settings:saveSetting('document_metadata_folder',mode) end
    Doc.setIsHashLocationEnabled(hash_enabled)
    assert(count('/web/mp/content')+count('/web/mp/articles')+count('/api/agent/gateway')==requests
        and count('/web/book/read')==writes and count('/web/login/renewal')==renewals,'metadata validation made account API calls')
    write(home..'/../evidence/mp-metadata.json',client:json_encode(report))
    print('PASS: MP metadata doc/dir/hash -> sampled-hash collision control, immutable revision isolation, native history, CRE, cleanup/repair and notes preservation')
end

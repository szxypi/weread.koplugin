package.path='./?.lua;./?/init.lua;'..package.path
local real=os.getenv('WEREAD_REAL_RUNTIME')=='1'
local H=real and {connect=require('lua-ljsqlite3/init').open} or require('spec.helpers.annotation_test_store')
if not real then package.preload['lua-ljsqlite3/init']=function() return {open=H.connect} end end
local Task=require('weread.lib.readtime_transfer_task');local Signing=require('weread.lib.readtime_protocol')
local Native=require('weread.lib.native_read_access')
require('spec.helpers.thought_edit_fixture')
local Json=require('json')
local n=0;local function expect(v,why) n=n+1;assert(v,why or ('check '..n)) end
local roots={};local original_zone=Signing.time_zone;Signing.time_zone=function() return '+08:00' end
local function fixture(mode) return require('spec.helpers.readtime_transfer_fixture').new(mode,expect,roots) end
local f=fixture();local result=f.run()
expect(result.kind=='confirmed' and result.attempted and result.acknowledged and result.stable_reads==2)
expect(f.posts==1 and f.ledger:summary(f.account).confirmed==2 and f.journal:pending(f.account)==nil)
expect(result.removed_zero_buckets==2 and f.source_reads==2)
expect(f.body.books[1].readingTime==2 and f.body.books[1].hours[1].startOfHour==math.floor((1700007200-86400)/3600)*3600)
expect(f.body.books[1].summary=='' and f.body.books[1].chapterUid==nil and f.body.books[1].isResendReadingInfo==1)
local db=H.connect(f.coverage.path);local q=db:prepare('SELECT phase,evidence FROM offline_time_records');local row=q:step();q:close();db:close()
expect(row[1]=='settled' and Json.decode(row[2]).audit.removed_zero_buckets==2,'permanent zero-removal audit missing')
result=f.run();expect(not result.attempted and f.posts==1,'settled intent replayed')
f=fixture('delay');result=f.run();expect(result.kind=='confirmed' and result.readbacks==3 and f.posts==1)
for _i,mode in ipairs({'current_day','position','tts','source_changed','no_delta','no_ack','lost','cancel_post'}) do
    f=fixture(mode);result=f.run()
    expect(result.kind=='unconfirmed' and result.attempted and f.posts==1,mode)
    expect(f.ledger:summary(f.account).confirmed==0 and f.journal:pending(f.account)~=nil,mode)
    result=f.run();expect(not result.attempted and f.posts==1,'unknown replayed: '..mode)
end
f=fixture('cancel_pre');result=f.run();expect(not result.attempted and f.posts==0 and f.ledger:summary(f.account).pending==2)
f=fixture();db=H.connect(f.coverage.path);local fail_ack=db:prepare([[CREATE TRIGGER fail_ack BEFORE UPDATE ON offline_time_records
    WHEN NEW.phase='acknowledged' BEGIN SELECT RAISE(ABORT,'fixture'); END]]);fail_ack:step();fail_ack:close();db:close()
result=f.run();expect(result.kind=='unconfirmed' and result.acknowledged and f.posts==1 and f.journal:pending(f.account).phase=='claimed')
expect(f.ledger:summary(f.account).confirmed==0)
f=fixture();db=H.connect(f.coverage.path);local fail_settle=db:prepare([[CREATE TRIGGER fail_settle BEFORE UPDATE ON offline_time_records
    WHEN NEW.phase='settled' BEGIN SELECT RAISE(ABORT,'fixture'); END]]);fail_settle:step();fail_settle:close();db:close()
result=f.run();expect(result.kind=='saved_confirmation' and f.posts==1 and f.journal:pending(f.account).phase=='confirmed')
expect(f.ledger:summary(f.account).confirmed==2)
db=H.connect(f.coverage.path);db:exec('DROP TRIGGER fail_settle');db:close()
expect(f.journal:recover(f.account)==true and f.journal:pending(f.account)==nil and f.ledger:summary(f.account).confirmed==2)
f=fixture('metadata_version');result=f.run();expect(not result.attempted and f.posts==0 and f.ledger:summary(f.account).pending==2)
for _i,kind in ipairs({'account','interval','version','file','seconds'}) do
    f=fixture()
    if kind=='account' then f.options.account=string.rep('b',20) end
    if kind=='interval' then f.selection.protocol_rows[1].start_time=f.selection.protocol_rows[1].start_time+3600 end
    if kind=='version' then f.selection.book_version=8 end
    if kind=='file' then f.selection.file_id=string.rep('c',64) end
    if kind=='seconds' then f.selection.seconds=3 end
    result=f.run();expect(not result.attempted and f.posts==0 and f.source_reads==0 and f.ledger:summary(f.account).pending==2,kind)
end
-- An interrupted ACK is resolved in a new access context by GETs only.
f=fixture('no_delta');result=f.run();expect(result.kind=='unconfirmed' and f.journal:pending(f.account).phase=='acknowledged')
local record=f.journal:pending(f.account);local original_metadata -- full frozen baseline compared below
local Contract=require('weread.lib.readtime_transfer_contract')
original_metadata=Contract.digest(record.metadata)
f.applied=true;f.mode=nil;f.clock=f.clock+86400;f.state.revision=f.state.revision+1
f.native=Native.capture(f.settings,f.native.store)
local configs=f.configs
result=Task.resolve(f.client,f.settings,f.native,f.web,record,{},f.journal,f.options)
expect(result.kind=='confirmed' and not result.attempted and result.acknowledged and result.stable_reads==2)
expect(f.posts==1 and f.configs==configs and f.ledger:summary(f.account).confirmed==2)
expect(Contract.digest(assert(f.journal:get(f.account,record.attempt)).metadata)==original_metadata)
result=Task.resolve(f.client,f.settings,f.native,f.web,record,{},f.journal,f.options)
expect(result.kind=='unavailable' and f.posts==1,'settled ACK resolved twice')
for _i,mode in ipairs({'lost','no_ack','position','source_changed'}) do
    f=fixture(mode);f.run();record=f.journal:pending(f.account);local reads=f.reads
    result=Task.resolve(f.client,f.settings,f.native,f.web,record,{},f.journal,f.options)
    expect(result.kind~='confirmed' and not result.attempted and f.posts==1 and f.ledger:summary(f.account).confirmed==0,mode)
    if mode=='lost' or mode=='no_ack' then expect(f.reads==reads,'no ACK authorized reads') end
end
for _i,changed in ipairs({'account','device','owner','guard'}) do
    f=fixture('no_delta');f.run();record=f.journal:pending(f.account);f.applied=true;f.mode=nil;local reads=f.reads
    if changed=='account' then f.options.account=string.rep('a',20)
    elseif changed=='device' then f.native.credentials.deviceId='eink334691225'..string.rep('2',19)
    elseif changed=='owner' then f.state.valid=false else f.current=false end
    result=Task.resolve(f.client,f.settings,f.native,f.web,record,{},f.journal,f.options)
    expect(result.kind=='unavailable' and not result.attempted and f.posts==1 and f.reads==reads,changed)
end
-- Missing and empty summaries are different observable states, neither a
-- made-up position excerpt. Time-only sends preserve their exact presence.
for _i,mode in ipairs({'absent_summary','empty_summary'}) do
    f=fixture(mode);result=f.run()
    expect(result.kind=='confirmed' and f.posts==1 and f.ledger:summary(f.account).confirmed==2,mode)
    expect(f.journal:get(f.account,result.attempt).metadata.position_contract=='historical-time-point-presence-v1')
end
for _i,mode in ipairs({'summary_presence_changed','summary_disappeared'}) do
    f=fixture(mode);result=f.run()
    expect(result.kind=='unconfirmed' and f.posts==1 and f.journal:pending(f.account).phase=='acknowledged',mode)
    expect(f.ledger:summary(f.account).confirmed==0)
end
-- Imported-book historical transfer is reachable only through the explicit
-- experimental gate. Neither the plaintext summary nor source enters metadata.
f=require('spec.helpers.readtime_transfer_fixture').new(nil,expect,roots,true)
f.options.experimental_cb=false;result=f.run()
expect(not result.attempted and f.posts==0 and f.ledger:summary(f.account).pending==2,'CB gate')
f.options.experimental_cb=true;local original_observer=f.options.observe_source
f.options.observe_source=function() error('readtime_source/format') end;result=f.run()
expect(result.kind=='unsupported_source' and not result.attempted and f.posts==0
    and f.ledger:summary(f.account).pending==2,'unsupported imported format')
f.options.observe_source=original_observer
f.options.experimental_cb=true;result=f.run()
expect(result.kind=='confirmed' and result.attempted and f.posts==1 and f.ledger:summary(f.account).confirmed==2,'CB send')
expect(f.body.books[1].bookId=='CB_Synthetic' and f.body.books[1].summary=='Synthetic complete summary')
record=assert(f.journal:get(f.account,result.attempt))
expect(record.metadata.protocol=='native-historical-time-cst-cb-v1'
    and not Json.encode(record.metadata):find('Synthetic complete summary',1,true),'CB metadata leaked summary')
result=f.run();expect(not result.attempted and f.posts==1,'CB settled replay')
for _i,mode in ipairs({'absent_summary','empty_summary','cb_summary_mismatch','cb_summary_changed_before','cb_web_counter_mismatch','metadata_version'}) do
    f=require('spec.helpers.readtime_transfer_fixture').new(mode,expect,roots,true);result=f.run()
    expect(not result.attempted and f.posts==0 and f.ledger:summary(f.account).pending==2,mode)
end
for _i,mode in ipairs({'summary_disappeared','position','lost','no_ack','source_changed','tts','current_day','cb_web_counter_changed'}) do
    f=require('spec.helpers.readtime_transfer_fixture').new(mode,expect,roots,true);result=f.run()
    expect(result.kind=='unconfirmed' and result.attempted and f.posts==1,mode)
    expect(f.ledger:summary(f.account).confirmed==0 and f.journal:pending(f.account)~=nil,mode)
    result=f.run();expect(not result.attempted and f.posts==1,'CB unknown replayed: '..mode)
end
f=require('spec.helpers.readtime_transfer_fixture').new('cb_web_counter_delay',expect,roots,true);result=f.run()
expect(result.kind=='confirmed' and result.readbacks==3 and f.posts==1,'CB Web counter lag')
f=require('spec.helpers.readtime_transfer_fixture').new('no_delta',expect,roots,true);result=f.run()
expect(result.kind=='unconfirmed' and f.journal:pending(f.account).phase=='acknowledged')
record=f.journal:pending(f.account);f.applied=true;f.mode=nil;local cb_configs=f.configs
result=Task.resolve(f.client,f.settings,f.native,f.web,record,{},f.journal,f.options)
expect(result.kind=='confirmed' and not result.attempted and f.posts==1 and f.configs==cb_configs,'CB read-only resolution')
-- Chain imported raw TXT archive proof into the actual historical task.
local Source=require('weread.lib.position_source');local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto');local Current=require('weread.lib.source_currentness')
local raw='Synthetic original TXT.\r\nSecond line.';local rendered='<html><body>Synthetic render</body></html>'
local chapters={{chapterUid=7,chapterIdx=0}}
local refs={{file='/synthetic-txt.epub',chapter_uid='7',chapter_idx=0}}
local function txt_fixture(mode,unversioned)
    local version=unversioned and 0 or 7
    local book={bookId='CB_Synthetic',bookVersion=version}
    local id_raw=Identity.encode(book,chapters,Identity.capture(book),Crypto.sha256_hex(raw),version)
    local id=assert(Identity.decode(id_raw));local captured=assert(Source.capture(book,chapters[1],raw,'web_txt'))
    local metadata=assert(Source.bind(captured,id,'OEBPS/text/chapter.xhtml',Crypto.sha256_hex(rendered)))
    local members={[Identity.PATH]=id_raw,[Source.meta_path('7')]=metadata,
        [Source.raw_path(captured.raw_sha256)]=raw,['OEBPS/text/chapter.xhtml']=rendered}
    local item=require('spec.helpers.readtime_transfer_fixture').new(mode,expect,roots,true,
        {file_id=id.file_id,book_version=version,version_source=unversioned and 'epub_unknown' or 'epub_snapshot'})
    local options={read_archive=function(_file,wanted)
        local out={} for key,maximum in pairs(wanted) do
            local value=members[key]
            if item.mode=='txt_source_changed' and item.posts>0 and key==Source.raw_path(captured.raw_sha256) then value='changed' end
            if not value or #value>maximum then return nil end;out[key]=value
        end
        return out
    end,fetch=function(_client,expected,_web,format,configuration,cb)
        expect(cb and format=='web_txt')
        local catalog_book={bookId=book.bookId}
        if item.mode=='txt_version' then catalog_book.bookVersion=8
        elseif not unversioned then catalog_book.bookVersion=7 end
        local catalog={{bookId=book.bookId,book=catalog_book,updated=chapters}}
        configuration.verify_catalog(catalog)
        if item.mode=='txt_catalog_changed' then catalog_book.bookVersion=0 end
        configuration.verify_catalog(catalog)
        local proof=Current.project_cb(expected,catalog,{book_id=book.bookId,psvts='synthetic-session'},raw,catalog)
        proof.basis='raw_txt_utf16';return proof
    end}
    item.options.observe_source=function(client,web,selection,_references,previous)
        return require('weread.lib.readtime_source').observe(client,web,selection,refs,previous,options)
    end
    return item
end
f=txt_fixture();result=f.run()
expect(result.kind=='confirmed' and f.posts==1 and f.ledger:summary(f.account).confirmed==2,'CB TXT historical send')
expect(assert(f.journal:get(f.account,result.attempt)).metadata.source.format=='web_txt','CB TXT proof not retained')
f=txt_fixture('txt_version');result=f.run()
expect(result.kind=='unavailable' and not result.attempted and f.posts==0 and f.ledger:summary(f.account).pending==2,'CB TXT version')
f=txt_fixture('txt_source_changed');result=f.run()
expect(result.kind=='unconfirmed' and result.attempted and f.posts==1 and f.journal:pending(f.account)~=nil,'CB TXT changed source')
result=f.run();expect(not result.attempted and f.posts==1,'CB TXT changed source replayed')
f=txt_fixture('no_ack');result=f.run()
expect(result.kind=='unconfirmed' and result.attempted and f.posts==1 and f.journal:pending(f.account)~=nil,'CB TXT no ACK')
result=f.run();expect(not result.attempted and f.posts==1,'CB TXT no ACK replayed')
f=txt_fixture(nil,true);result=f.run()
expect(result.kind=='confirmed' and f.posts==1 and f.body.books[1].bookVersion==0,'CB zero-version TXT historical send')
record=assert(f.journal:get(f.account,result.attempt))
expect(record.metadata.book_version==0 and record.metadata.source.format=='web_txt','zero-version source not retained')
for _i,mode in ipairs({'txt_version','txt_catalog_changed','metadata_version','metadata_conflict','metadata_missing','metadata_zero_string'}) do
    f=txt_fixture(mode,true);result=f.run()
    expect(not result.attempted and f.posts==0 and f.ledger:summary(f.account).pending==2,mode)
end
f=txt_fixture(nil,true);f.options.observe_source=function() return {format='web_xhtml'} end;result=f.run()
expect(not result.attempted and f.posts==0,'zero-version non-TXT source accepted')
for _i,mode in ipairs({'txt_source_changed','metadata_changed_after','no_ack'}) do
    f=txt_fixture(mode,true);result=f.run()
    expect(result.kind=='unconfirmed' and result.attempted and f.posts==1,mode)
    result=f.run();expect(not result.attempted and f.posts==1,'zero-version unknown replayed: '..mode)
end
f=txt_fixture('no_delta',true);result=f.run();record=f.journal:pending(f.account)
expect(result.kind=='unconfirmed' and record.phase=='acknowledged','zero-version ACK saved')
f.applied=true;f.mode=nil;local zero_configs=f.configs
result=Task.resolve(f.client,f.settings,f.native,f.web,record,{},f.journal,f.options)
expect(result.kind=='confirmed' and not result.attempted and f.posts==1 and f.configs==zero_configs,'zero-version read-only resolution')
local function multi_txt_fixture(mode)
    local multi={{chapterUid=7,chapterIdx=0,wordCount=100},{chapterUid=8,chapterIdx=3,wordCount=100}}
    local book={bookId='CB_Synthetic',bookVersion=0}
    local root=Identity.encode(book,multi,Identity.capture(book),Crypto.sha256_hex('synthetic multi book'),0)
    local id=assert(Identity.decode(root));local members={[Identity.PATH]=root};local names={}
    for i,chapter in ipairs(multi) do
        local text='Synthetic multi source '..i;local html='<p>'..text..'</p>'
        local path=string.format('OEBPS/text/chapter-%03d.xhtml',i)
        local source=assert(Source.capture(book,chapter,text,'web_txt'))
        local meta=assert(Source.bind(source,id,path,Crypto.sha256_hex(html)))
        local name=Source.meta_path(tostring(chapter.chapterUid));names[i]=name
        members[name],members[Source.path_meta_path(path)]=meta,meta
        members[Source.raw_path(source.raw_sha256)],members[path]=text,html
    end
    local item=require('spec.helpers.readtime_transfer_fixture').new(mode,expect,roots,true,
        {file_id=id.file_id,book_version=0,version_source='epub_unknown'})
    local options={read_archive=function(_file,wanted)
        local out={}
        for key,maximum in pairs(wanted) do
            local value=members[key]
            if item.mode=='multi_after' and item.posts>0 and key=='OEBPS/text/chapter-002.xhtml' then value='changed' end
            if not value or #value>maximum then return nil end;out[key]=value
        end
        return out
    end,list_metadata=function()
        return {{name=names[1],metadata=members[names[1]]},{name=names[2],metadata=members[names[2]]}}
    end,fetch=function(_client,expected,_web,format,configuration,cb)
        expect(cb and format=='web_txt')
        local catalog={{bookId=book.bookId,book={bookId=book.bookId},updated=multi}}
        if item.mode=='multi_version' then catalog[1].book.version=0 end
        configuration.verify_catalog(catalog);configuration.verify_catalog(catalog)
        local text='Synthetic multi source '..(expected.chapter_uid=='7' and 1 or 2)
        if item.mode=='multi_source' and expected.chapter_uid=='8' then text='different' end
        local proof=Current.project_cb(expected,catalog,{book_id=book.bookId,psvts='synthetic-session'},text,catalog)
        proof.basis='raw_txt_utf16';return proof
    end}
    local reader=require('weread.lib.readtime_source')
    local book_refs=assert(reader.references({cached_full_book='/synthetic-multi.epub'},multi,
        {book_id=book.bookId,book_version=0,file_id=id.file_id}))
    item.options.observe_source=function(client,web,selection,_references,previous)
        return reader.observe(client,web,selection,book_refs,previous,options)
    end
    return item
end
f=multi_txt_fixture();result=f.run()
expect(result.kind=='confirmed' and f.posts==1 and f.body.books[1].bookVersion==0,'multi TXT historical send')
record=assert(f.journal:get(f.account,result.attempt))
expect(record.metadata.source.chapter_count==2 and record.metadata.source.entries==nil,'multi TXT compact proof')
for _i,mode in ipairs({'multi_source','multi_version'}) do
    f=multi_txt_fixture(mode);result=f.run()
    expect(not result.attempted and f.posts==0,'multi TXT must reject '..mode)
end
for _i,mode in ipairs({'multi_after','no_ack'}) do
    f=multi_txt_fixture(mode);result=f.run()
    expect(result.kind=='unconfirmed' and result.attempted and f.posts==1,'multi TXT must retain '..mode)
    result=f.run();expect(not result.attempted and f.posts==1,'multi TXT unknown replayed')
end
f=multi_txt_fixture('no_delta');result=f.run();record=f.journal:pending(f.account)
expect(result.kind=='unconfirmed' and record.phase=='acknowledged','multi TXT ACK saved')
f.applied=true;f.mode=nil;local multi_configs=f.configs
result=Task.resolve(f.client,f.settings,f.native,f.web,record,{},f.journal,f.options)
expect(result.kind=='confirmed' and not result.attempted and f.posts==1 and f.configs==multi_configs,'multi TXT read-only resolution')
-- Native chapter rows use the production dispatch adapter and durable ledger;
-- the source verifier is substituted with a deterministic read-only proof.
local Direct=require('weread.lib.native_direct_readtime_source');local direct_observe=Direct.observe
local direct_ref={kind='native_direct',file='/synthetic-direct.epub',chapter_uid='7',source_sha256=string.rep('b',64)}
local function direct_fixture(mode)
    local item=require('spec.helpers.readtime_transfer_fixture').new(mode,expect,roots,false,{version_source='native_direct'})
    item.options.observe_source=nil
    Direct.observe=function(_client,_settings,account,selection,file,_native,_web,current,previous)
        item.source_reads=item.source_reads+1
        if not current() or item.mode=='source_changed' and previous and item.posts>0
            or item.mode=='source_before' and previous then return nil end
        expect(account==item.account and selection.file_id==item.file_id and file==direct_ref.file)
        return {kind='native_direct',ref=direct_ref,account=account,file_id=selection.file_id}
    end
    return item
end
f=direct_fixture();expect(f.selection.native_direct==true,'native row not selected')
result=Task.run(f.client,f.settings,f.native,f.web,f.selection,{direct_ref},f.journal,f.options)
expect(result.kind=='confirmed' and f.posts==1 and f.ledger:summary(f.account).confirmed==2,'native time did not settle')
record=assert(f.journal:get(f.account,result.attempt))
expect(record.metadata.source.kind=='native_direct' and record.metadata.source.account==f.account,'native source not journaled')
expect(f.source_reads==3,'native source was not checked before and after dispatch')
result=Task.run(f.client,f.settings,f.native,f.web,f.selection,{direct_ref},f.journal,f.options)
expect(not result.attempted and f.posts==1,'native settled time replayed')
f=direct_fixture('source_before')
result=Task.run(f.client,f.settings,f.native,f.web,f.selection,{direct_ref},f.journal,f.options)
expect(not result.attempted and f.posts==0 and f.ledger:summary(f.account).pending==2,'changed source reached dispatch')
for _i,mode in ipairs({'lost','no_ack','source_changed'}) do
    f=direct_fixture(mode)
    result=Task.run(f.client,f.settings,f.native,f.web,f.selection,{direct_ref},f.journal,f.options)
    expect(result.kind=='unconfirmed' and result.attempted and f.posts==1,mode)
    result=Task.run(f.client,f.settings,f.native,f.web,f.selection,{direct_ref},f.journal,f.options)
    expect(not result.attempted and f.posts==1,'native uncertain transfer replayed')
end
f=direct_fixture('no_delta')
result=Task.run(f.client,f.settings,f.native,f.web,f.selection,{direct_ref},f.journal,f.options)
record=f.journal:pending(f.account);expect(result.kind=='unconfirmed' and record.phase=='acknowledged')
f.applied=true;f.mode=nil;local direct_configs=f.configs
result=Task.resolve(f.client,f.settings,f.native,f.web,record,{direct_ref},f.journal,f.options)
expect(result.kind=='confirmed' and not result.attempted and f.posts==1 and f.configs==direct_configs,'native read-only resolution')
Direct.observe=direct_observe
-- Exercise the real native source proof and transfer adapter together. Only
-- the chapter fetches and archive lookup are synthetic; verification,
-- selection, durable claim, accounting and readback are production code.
do
    local Cache=require('weread.lib.native_direct_cache')
    local NativeSource=require('weread.lib.native_chapter_source')
    local DirectCurrent=require('weread.lib.source_currentness')
    local old_identify,old_fetch,old_web_fetch,old_resolve=Cache.identify,NativeSource.fetch,DirectCurrent.fetch,DirectCurrent.fetch_resolving_index
    local direct_body='<html><body><p>Synthetic native chapter text.</p></body></html>'
    f=require('spec.helpers.readtime_transfer_fixture').new(nil,expect,roots,false,{version_source='native_direct'})
    f.options.observe_source=nil
    local direct_entry={owner=Crypto.sha256_hex('native-direct-account\0'..f.native.scope.vid),book_id='42',chapter_uid='7',
        chapter_idx=0,book_version=7,title='Synthetic',missing_images=0,text_digest=string.rep('a',64),
        source_sha256=Crypto.sha256_hex(direct_body),file_id=f.file_id,key=string.rep('b',64),copy=0}
    local reference={kind='native_direct',file='/synthetic/source.epub',chapter_uid='7',source_sha256=direct_entry.source_sha256}
    Cache.identify=function(_settings,_vid,file,current) return current() and file==reference.file and direct_entry or nil end
    NativeSource.fetch=function() return {is_text=false,book_version=7,body=direct_body} end
    DirectCurrent.fetch=function(_client,expected,_web,_format,options)
        local catalog={{bookId='42',bookVersion=7}}
        options.verify_catalog(catalog);options.verify_catalog(catalog)
        local proof={};for key,value in pairs(expected) do proof[key]=value end
        proof.catalog_stamp=string.rep('d',64);proof.source_current=true;proof.upload_verified=false
        return proof
    end
    result=Task.run(f.client,f.settings,f.native,f.web,f.selection,{reference},f.journal,f.options)
    expect(result.kind=='confirmed' and f.posts==1,'real native source proof did not reach verified accounting')
    record=assert(f.journal:get(f.account,result.attempt))
    expect(record.metadata.source.source_sha256==reference.source_sha256 and record.metadata.source.ref.file==reference.file,
        'native source proof was not bound to journal')
    f=require('spec.helpers.readtime_transfer_fixture').new(nil,expect,roots,false,{version_source='native_direct'})
    f.options.observe_source=nil;direct_entry.chapter_idx=nil;direct_entry.file_id=f.file_id
    DirectCurrent.fetch_resolving_index=function(client,expected,web,options)
        expect(expected.chapter_idx==nil and options.resolve_index==true,'index resolution was not scoped to time')
        local copy={};for key,value in pairs(expected) do copy[key]=value end;copy.chapter_idx=0
        return DirectCurrent.fetch(client,copy,web,'web_xhtml',options)
    end
    result=Task.run(f.client,f.settings,f.native,f.web,f.selection,{reference},f.journal,f.options)
    expect(result.kind=='confirmed' and f.posts==1 and direct_entry.chapter_idx==nil,'index-free chapter time did not settle')
    record=assert(f.journal:get(f.account,result.attempt))
    expect(record.metadata.source.chapter_idx==0,'resolved index not bound to time proof')
    Cache.identify,NativeSource.fetch,DirectCurrent.fetch,DirectCurrent.fetch_resolving_index=old_identify,old_fetch,old_web_fetch,old_resolve
end
Signing.time_zone=original_zone
for _i,root in ipairs(roots) do os.execute('rm -rf '..string.format('%q',root)) end
print('readtime_transfer_task_spec: '..n..' checks')

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
local book={bookId='CB_Synthetic',bookVersion=7};local chapters={{chapterUid=7,chapterIdx=0}}
local id_raw=Identity.encode(book,chapters,Identity.capture(book),Crypto.sha256_hex(raw),7)
local id=assert(Identity.decode(id_raw));local captured=assert(Source.capture(book,chapters[1],raw,'web_txt'))
local metadata=assert(Source.bind(captured,id,'OEBPS/text/chapter.xhtml',Crypto.sha256_hex(rendered)))
local members={[Identity.PATH]=id_raw,[Source.meta_path('7')]=metadata,
    [Source.raw_path(captured.raw_sha256)]=raw,['OEBPS/text/chapter.xhtml']=rendered}
local refs={{file='/synthetic-txt.epub',chapter_uid='7',chapter_idx=0}}
local function txt_fixture(mode)
    local item=require('spec.helpers.readtime_transfer_fixture').new(mode,expect,roots,true,{file_id=id.file_id})
    local options={read_archive=function(_file,wanted)
        local out={} for key,maximum in pairs(wanted) do
            local value=members[key]
            if item.mode=='txt_source_changed' and item.posts>0 and key==Source.raw_path(captured.raw_sha256) then value='changed' end
            if not value or #value>maximum then return nil end;out[key]=value
        end
        return out
    end,fetch=function(_client,expected,_web,format,configuration,cb)
        expect(cb and format=='web_txt')
        local catalog={{bookId=book.bookId,book={bookVersion=item.mode=='txt_version' and 8 or 7},updated=chapters}}
        configuration.verify_catalog(catalog);configuration.verify_catalog(catalog)
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
Signing.time_zone=original_zone
for _i,root in ipairs(roots) do os.execute('rm -rf '..string.format('%q',root)) end
print('readtime_transfer_task_spec: '..n..' checks')

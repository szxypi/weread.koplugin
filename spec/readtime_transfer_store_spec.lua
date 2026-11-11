package.path='./?.lua;./?/init.lua;'..package.path
local H=require('spec.helpers.annotation_test_store')
package.preload['lua-ljsqlite3/init']=function() return {open=H.connect} end
local Ledger=require('weread.lib.offline_time_store')
local Coverage=require('weread.lib.readtime_coverage')
local Journal=require('weread.lib.readtime_transfer_store')
local C=require('weread.lib.readtime_transfer_contract')
local Json=require('json');local codec={json_encode=function(_self,x) return Json.encode(x) end,json_decode=function(_self,x) return Json.decode(x) end}
local checks=0;local function eq(a,b) checks=checks+1;assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local roots={};local account=string.rep('a',20);local second=string.rep('b',20)
local function fixture()
    local root=os.tmpname()..'-offline-transfer';os.execute('mkdir -p '..string.format('%q',root));roots[#roots+1]=root
    local ledger=Ledger:new(root);local coverage=Coverage:new(root,function() return 100 end);assert(coverage:initialize())
    local window=assert(ledger:begin(account,{book_id='42',stats_book=1,start_time=100,time_zone='+08:00',book_version=7,file_id=string.rep('f',64),version_source='epub_snapshot'}))
    assert(ledger:collect(account,window,{{page='1',start_time=100,duration=60}},160,true))
    assert(coverage:reserve(account,140,20));local rows=assert(ledger:pending(account))
    local preview=assert(coverage:preview(account,rows));local selected=assert(C.select(rows,preview,200))
    local journal=Journal:new{coverage=coverage,ledger=ledger,codec=codec,now=function() return 200 end,nonce=function() return string.rep('1',32) end}
    return ledger,coverage,journal,selected,root
end
local function queue_fixture() local entries={fixture()};return entries[1],entries[3],entries[4] end
local function begin(journal,selected) return assert(journal:begin(account,selected,{request_hash=string.rep('d',64),seconds=selected.seconds})) end
local function record_phase(journal) local r=journal:pending(account);return r and r.phase or 'idle' end
-- A partial online overlap produces two native portions and a retained online category.
local ledger,coverage,journal,selected=fixture();eq(selected.seconds,40);eq(#selected.parts,2)
local record=begin(journal,selected);eq(record.phase,'prepared');eq(#record.rows,2)
eq(ledger:summary(account).in_flight,40);eq(ledger:summary(account).covered,20);eq(ledger:summary(account).pending,0)
eq(ledger:owns(account,record.rows,record.attempt),true);eq(journal:begin(account,selected,record.metadata),nil)
local saved,reason,resume_at=coverage:reserve(account,170,30)
eq(saved,nil);eq(reason,'offline_overlap');eq(resume_at,190)
eq(coverage:reserve(second,170,30),true)
saved,reason,resume_at=coverage:reserve(nil,170,30);eq(saved,nil);eq(reason,'offline_overlap');eq(resume_at,190)
eq(coverage:reserve(account,190,30),true) -- exact half-open boundary
-- Only one durable claim, and only the fresh claimed ledger snapshot, can dispatch.
eq(journal:claim(record),true);eq(journal:claim(record),nil);eq(journal:cancel_prepared(record),nil)
eq(journal:outcome(record,true),true);eq(journal:settle(record),true)
eq(record_phase(journal),'idle');eq(ledger:summary(account).confirmed,40);eq(ledger:summary(account).covered,20)
eq(coverage:preview(account,selected.rows).eligible,0)
eq(journal:claim(record),nil);eq(ledger:summary(account).in_flight,0)
-- A canceled preview/worker never leaves its source seconds claimed.
ledger,coverage,journal,selected=fixture();record=begin(journal,selected)
eq(journal:cancel_prepared(record),true);eq(ledger:summary(account).pending,40);eq(ledger:summary(account).covered,20)
eq(record_phase(journal),'idle');eq(coverage:reserve(account,170,30),true);eq(journal:claim(record),nil)
-- Reopen before transport claim is provably unsent, even if collector recovery ran.
ledger,journal,selected=queue_fixture();begin(journal,selected);assert(ledger:recover(account))
eq(ledger:summary(account).unknown,40);eq(journal:recover(account),true)
eq(ledger:summary(account).pending,40);eq(ledger:summary(account).unknown,0);eq(record_phase(journal),'idle')
-- A claimed request stays quarantined across recovery and can only be retired, not resent.
ledger,coverage,journal,selected=fixture();record=begin(journal,selected);assert(journal:claim(record));assert(ledger:recover(account))
eq(journal:recover(account),true);eq(record_phase(journal),'claimed');eq(ledger:summary(account).unknown,40)
eq(journal:cancel_prepared(record),nil);eq(journal:claim(record),nil)
eq(journal:retire_unknown(record),true);eq(record_phase(journal),'idle');eq(ledger:summary(account).unknown,40)
eq(coverage:reserve(account,170,30),nil);eq(journal:claim(record),nil)
-- Settlement can be interrupted between the two databases without double confirmation.
ledger,journal,selected=queue_fixture();record=begin(journal,selected);assert(journal:claim(record));assert(journal:outcome(record,true))
eq(ledger:settle_confirmed(account,record.rows,record.attempt),true);eq(ledger:summary(account).confirmed,40)
eq(journal:recover(account),true);eq(ledger:summary(account).confirmed,40);eq(record_phase(journal),'idle')
-- Failures roll back the ledger split, while a later coverage failure quarantines an orphan.
ledger,journal,selected=queue_fixture()
local db=H.connect(ledger:path(account));db:exec([[CREATE TRIGGER fail_split BEFORE INSERT ON segments BEGIN SELECT RAISE(ABORT,'fixture'); END]]);db:close()
eq(journal:begin(account,selected,{request_hash=string.rep('d',64)}),nil)
eq(ledger:summary(account).pending,60);eq(record_phase(journal),'idle')
ledger,coverage,journal,selected=fixture()
db=H.connect(coverage.path);db:exec([[CREATE TRIGGER fail_record BEFORE INSERT ON offline_time_records BEGIN SELECT RAISE(ABORT,'fixture'); END]]);db:close()
eq(journal:begin(account,selected,{request_hash=string.rep('d',64)}),nil)
eq(ledger:summary(account).in_flight,40);eq(record_phase(journal),'idle')
assert(ledger:recover(account));eq(journal:recover(account),true);eq(ledger:summary(account).unknown,40)
-- A changed online reservation invalidates the frozen native preview before the ledger changes.
ledger,coverage,journal,selected=fixture();assert(coverage:reserve(account,160,10))
eq(journal:begin(account,selected,{request_hash=string.rep('d',64)}),nil);eq(ledger:summary(account).pending,60)
-- Source snapshots and claims are exact, not merely matching row IDs.
ledger,journal,selected=queue_fixture();selected.rows[1].book_version=8
eq(journal:begin(account,selected,{request_hash=string.rep('d',64)}),nil);eq(ledger:summary(account).pending,60)
-- Settlement rollback retains a confirmed record; a second recovery does not add time twice.
ledger,coverage,journal,selected=fixture();record=begin(journal,selected);assert(journal:claim(record));assert(journal:outcome(record,true))
db=H.connect(coverage.path);db:exec([[CREATE TRIGGER fail_finish BEFORE DELETE ON offline_time_records BEGIN SELECT RAISE(ABORT,'fixture'); END]]);db:close()
eq(journal:settle(record),nil);eq(ledger:summary(account).confirmed,40);eq(record_phase(journal),'confirmed')
db=H.connect(coverage.path);db:exec('DROP TRIGGER fail_finish');db:close()
eq(journal:recover(account),true);eq(ledger:summary(account).confirmed,40);eq(record_phase(journal),'idle')
-- No ownership or settlement API accepts a legacy/unbound dispatch token.
eq(ledger:release_unsent(account,record.rows,''),nil);eq(ledger:settle_confirmed(account,record.rows,'old'),nil)
-- Sparse or decorated arrays cannot silently drop source rows, nor can a
-- duplicated source receipt count the same seconds twice.
ledger,coverage,journal,selected=fixture();record=begin(journal,selected)
local duplicates={record.rows[1],record.rows[1]}
eq(ledger:owns(account,duplicates,record.attempt),false)
eq(ledger:settle_confirmed(account,duplicates,record.attempt),nil)
eq(ledger:summary(account).confirmed,0);eq(ledger:summary(account).in_flight,40)
local decorated={record.rows[1],hidden=record.rows[2]}
eq(ledger:owns(account,decorated,record.attempt),false)
eq(ledger:release_unsent(account,decorated,record.attempt),nil)
local extra={};for key,value in pairs(record.rows[1]) do extra[key]=value end;extra.duration_override=1
eq(C.row(extra),false);eq(C.array({[1]=true,[3]=true},0,100),false)
eq(pcall(C.select,{extra},coverage:preview(account,{}),200),false)
local original=selected.parts;selected.parts={original[1],hidden=original[2]}
eq(journal:begin(second,selected,{request_hash=string.rep('d',64)}),nil)
selected.parts=original;eq(journal:claim(record),true);eq(journal:outcome(record,true),true)
eq(journal:settle(record),true);eq(ledger:summary(account).confirmed,40)
for _i,root in ipairs(roots) do os.execute('rm -rf '..string.format('%q',root)) end
print('readtime_transfer_store_spec: '..checks..' checks')

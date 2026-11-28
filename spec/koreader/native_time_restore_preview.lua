-- Isolated read-only preview of a sealed capture. No network or time overrides.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json')
local function deny() error('restore_preview/network_disabled') end
package.loaded['socket.http']={request=deny}
package.loaded['ssl.https']={request=deny}
assert(type(arg[1])=='string' and type(arg[2])=='string' and type(arg[3])=='string')
package.path=arg[1]..'/?.lua;'..package.path
local C=require('weread.lib.readtime_transfer_contract')
local Ledger=require('weread.lib.offline_time_store')
local Coverage=require('weread.lib.readtime_coverage')
local Queue=require('weread.lib.readtime_transfer_queue')
local Source=require('weread.lib.readtime_source')
local Account=require('weread.lib.native_position_contract').account_key
local plan=json.decode(assert(io.stdin:read('*a')))
assert(type(plan)=='table' and C.id(plan.owner) and C.id(plan.book_id) and C.id(plan.chapter_uid))
assert(C.integer(plan.not_before,1,4102444800) and os.time()>=plan.not_before)
assert(C.array(plan.rows,1,12) and C.integer(plan.seconds,5,12))
local synthetic=arg[4]=='synthetic'
assert(arg[4]==nil or synthetic)
if synthetic then assert(plan.owner=='900000' and plan.book_id=='900001' and plan.chapter_uid=='2') end
local account=assert(Account(plan.owner));local ledger=Ledger:new(arg[2])
local coverage=synthetic and Coverage:new(arg[2],function() return plan.start_time end) or Coverage:new(arg[2])
local tracked=assert(coverage:initialize())
assert(synthetic and tracked==plan.start_time or not synthetic and tracked>=plan.not_before)
assert(assert(ledger:summary(account)).rows==0)
local window=assert(ledger:begin(account,{book_id=plan.book_id,stats_book=1,start_time=plan.start_time,
    time_zone='+08:00',book_version=plan.book_version,file_id=plan.file_id,version_source='epub_snapshot'}))
local spans={}
for index,row in ipairs(plan.rows) do
    assert(C.row(row));spans[index]={page=tostring(index),start_time=row.start_time,duration=row.duration}
end
local collected=assert(ledger:collect(account,window,spans,plan.ended_at,true))
assert(collected.seconds==plan.seconds and collected.rows==#plan.rows)
local restored=assert(ledger:pending(account))
assert(C.digest(restored)==C.digest(plan.rows),'restore_preview/rows')
local source=Source.scan_page({cached_file=arg[3]},{{chapterUid=plan.chapter_uid,chapterIdx=plan.chapter_idx}},
    {book_id=plan.book_id,file_id=plan.file_id,book_version=plan.book_version},nil,1)
assert(source.kind=='found' and source.reference.file==arg[3] and source.reference.chapter_uid==plan.chapter_uid
    and source.reference.chapter_idx==plan.chapter_idx,'restore_preview/source')
local result=assert(Queue:new{ledger=ledger,coverage=coverage}:select(account,nil,{historical=true}))
if synthetic then
    assert(result.selection and result.selection.seconds==plan.seconds and result.report.untracked==0,'restore_preview/coverage')
    assert(C.digest(result.selection.rows)==C.digest(plan.rows),'restore_preview/selection')
else
    assert(result.selection==false and result.report.untracked==plan.seconds,'restore_preview/coverage')
end
local summary=assert(ledger:summary(account))
assert(summary.pending==plan.seconds and summary.in_flight==0 and summary.unknown==0 and summary.confirmed==0)
print('\nWEREAD_NATIVE_TIME_RESTORE_RESULT='..json.encode({result=synthetic and 'SYNTHETIC_TRACKED' or 'SAFE_UNTRACKED',seconds=plan.seconds,
    exact_saved_rows=true,archive_identity_verified=true,fresh_coverage_rejects_old_rows=not synthetic,
    pending_unchanged=true,account_data_posts=0,authentication_posts=0}))

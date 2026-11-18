-- Inspect restored capture evidence using the actual clock, without network.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json')
local function deny() error('bundle_inspect/network_disabled') end
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
local cb=arg[4]=='cb';assert(arg[4]==nil or cb)
assert(type(plan)=='table' and C.id(plan.owner) and (cb and C.cb_id(plan.book_id) or not cb and C.id(plan.book_id)) and C.id(plan.chapter_uid))
assert(C.integer(plan.not_before,1,4102444800) and os.time()>=plan.ended_at and os.time()<plan.not_before)
local account=assert(Account(plan.owner));local ledger=Ledger:new(arg[2]);local coverage=Coverage:new(arg[2])
local tracked=assert(coverage:initialize());assert(tracked<=plan.start_time)
local rows=assert(ledger:pending(account));assert(C.digest(rows)==C.digest(plan.rows))
local availability=assert(coverage:preview_individual(account,rows))
assert(availability.eligible==plan.seconds and availability.covered==0 and availability.unverified==0)
local source=Source.scan_page({cached_file=arg[3]},{{chapterUid=plan.chapter_uid,chapterIdx=plan.chapter_idx}},
    {book_id=plan.book_id,file_id=plan.file_id,book_version=plan.book_version},nil,1)
assert(source.kind=='found' and source.reference.file==arg[3] and source.reference.chapter_uid==plan.chapter_uid
    and source.reference.chapter_idx==plan.chapter_idx)
local selected=assert(Queue:new{ledger=ledger,coverage=coverage}:select(account,nil,{historical=true,allow_cb=cb}))
assert(selected.selection==false and selected.report.deferred==plan.seconds)
local summary=assert(ledger:summary(account))
assert(summary.pending==plan.seconds and summary.in_flight==0 and summary.unknown==0 and summary.confirmed==0)
print('\nWEREAD_NATIVE_BUNDLE_INSPECT_RESULT='..json.encode({result='SAME_DAY_DEFERRED',seconds=plan.seconds,
    exact_rows=true,archive_verified=true,coverage_verified=true,same_day_deferred=true,pending_unchanged=true,
    account_data_posts=0,authentication_posts=0}))

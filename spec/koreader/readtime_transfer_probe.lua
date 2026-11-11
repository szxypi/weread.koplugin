-- Official KOReader runtime, its SQLite binding and real competing workers.
-- Synthetic local seconds only; no credentials, accounts or network calls.
require('ffi').log=function() end
require('setupkoenv')
assert(type(arg[1])=='string' and type(arg[2])=='string')
package.path=arg[1]..'/?.lua;'..package.path
local Json=require('json')
local Native=require('ffi/util')
local Socket=require('socket')
local Ledger=require('weread.lib.offline_time_store')
local Coverage=require('weread.lib.readtime_coverage')
local Journal=require('weread.lib.readtime_transfer_store')
local Contract=require('weread.lib.readtime_transfer_contract')
local account=string.rep('a',20)
local codec={json_encode=function(_self,value) return Json.encode(value) end,json_decode=function(_self,value) return Json.decode(value) end}
local now=os.time()
local function fixture(name)
    local path=arg[2]..'/'..name
    assert(require('libs/libkoreader-lfs').mkdir(path),'probe directory must be new')
    local ledger=Ledger:new(path)
    local coverage=Coverage:new(path,function() return now-120 end);assert(coverage:initialize())
    local id=assert(ledger:begin(account,{book_id='42',stats_book=1,start_time=now-120,time_zone='+08:00',
        book_version=7,file_id=string.rep('f',64),version_source='epub_snapshot'}))
    assert(ledger:collect(account,id,{{page='1',start_time=now-120,duration=60}},now,true))
    assert(coverage:reserve(account,now-80,20))
    local rows=assert(ledger:pending(account))
    local selection=assert(Contract.select(rows,assert(coverage:preview(account,rows)),now))
    assert(selection.seconds==40)
    local journal=Journal:new{coverage=coverage,ledger=ledger,codec=codec}
    local record=assert(journal:begin(account,selection,{request_hash=string.rep('d',64)}))
    return ledger,coverage,journal,record
end
local function spawn(callback)
    local pid,fd=Native.runInSubProcess(function(_pid,child_fd)
        local ok,result=pcall(callback)
        Native.writeToFD(child_fd,ok and result or 'FAIL',true)
    end,true)
    assert(pid,'probe fork failed');return {pid=pid,fd=fd}
end
local function collect(worker)
    local deadline=Socket.gettime()+10
    while not Native.isSubProcessDone(worker.pid) do
        if Socket.gettime()>deadline then Native.terminateSubProcess(worker.pid);error('probe worker timeout') end
        Socket.sleep(.02)
    end
    return Native.readAllFromFD(worker.fd)
end
local ledger,coverage,journal,record=fixture('competing')
local function claim() return journal:claim(record)==true and 'CLAIMED' or 'DENIED' end
local first,second=spawn(claim),spawn(claim)
local a,b=collect(first),collect(second)
assert(a=='CLAIMED' and b=='DENIED' or a=='DENIED' and b=='CLAIMED','exactly one worker may claim')
assert(journal:recover(account));assert(journal:pending(account).phase=='claimed')
assert(ledger:recover(account));assert(ledger:summary(account).unknown==40)
local concurrent=spawn(function()
    local saved,reason,resume_at=coverage:reserve(account,now-50,30)
    assert(not saved and reason=='offline_overlap' and resume_at==now-30)
    return 'SEALED'
end)
assert(collect(concurrent)=='SEALED','coverage was not visible across processes')
assert(not journal:claim(record));assert(not journal:cancel_prepared(record))
assert(journal:retire_unknown(record));assert(not journal:pending(account))
assert(ledger:summary(account).unknown==40 and not coverage:reserve(account,now-50,30))
ledger,coverage,journal,record=fixture('cancel')
assert(ledger:recover(account));assert(journal:recover(account))
assert(ledger:summary(account).pending==40 and ledger:summary(account).covered==20)
assert(collect(spawn(function() return journal:claim(record) and 'CLAIMED' or 'DENIED' end))=='DENIED')
assert(coverage:reserve(account,now-50,30))
ledger,coverage,journal,record=fixture('settle')
assert(journal:claim(record));assert(journal:outcome(record,true))
assert(ledger:settle_confirmed(account,record.rows,record.attempt))
assert(journal:recover(account));assert(journal:recover(account))
assert(ledger:summary(account).confirmed==40 and ledger:summary(account).covered==20)
assert(not journal:pending(account));assert(not journal:claim(record))
local plan=assert(coverage:preview(account,record.rows));assert(plan.covered==40 and plan.eligible==0)
print(Json.encode({result='PASS',competing_workers=2,successful_claims=1,canceled_worker_denied=true,
    claimed_restart_no_replay=true,retired_unknown_seconds=40,settled_once_seconds=40,covered_seconds=20,
    cross_process_online_admission=true,network_requests=0}))

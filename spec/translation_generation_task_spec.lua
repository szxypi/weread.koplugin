package.path='./?.lua;'..package.path
local hash=string.rep('a',64)
local w={};local store={}
local function reset()
    w={valid=true,source_calls=0,baseline_calls=0,mode_calls=0,generation_calls=0,record=nil}
end
reset()
local selected={scope={vid='123'},fingerprint=hash}
local web={web={cookies={wr_vid='123'}}}
local input={book_id='456',chapter_uid='7'}
local function source()
    w.source_calls=w.source_calls+1
    if w.missing_source then return nil end
    if w.available or w.available_during_recheck and w.source_calls>=2 or w.generated and w.available_after_generation then
        return {kind='available',book_id='456',chapter_uid='7'}
    end
    return {kind='source_verified',book_id='456',chapter_uid='7',version=7,translate_version=0,
        catalog_sha256=hash,source_sha256=hash,file_id=hash}
end
package.loaded['weread.lib.native_read_access']={matches=function() return w.valid end}
package.loaded['weread.lib.read_access']={matches=function() return w.valid end}
package.loaded['weread.lib.translation_generation_source']={inspect=function() return source() end}
package.loaded['weread.lib.translation_generation_baseline']={read=function()
    w.baseline_calls=w.baseline_calls+1
    if w.error_after_mode and w.mode_calls>0 then error('synthetic') end
    return {digest=w.changed_baseline and w.baseline_calls>1 and string.rep('b',64) or hash,position_present=true}
end}
package.loaded['weread.lib.translation_generation_dispatch']={send_once=function(_client,_settings,_selected,plan,_journal,operation,options)
    local witness,baseline=options.recheck()
    if not witness or baseline~=hash or witness.source_sha256~=plan.source_sha256 then return {kind='unavailable',attempted=false} end
    if operation=='mode' then
        w.mode_calls=w.mode_calls+1;w.record={phase='mode_confirmed'}
        if w.mode_unknown then w.record.phase='mode_claimed';return {kind='unconfirmed',attempted=true} end
        return {kind='mode_confirmed',attempted=true}
    end
    w.generation_calls=w.generation_calls+1;w.generated=true
    if w.generation_unknown then w.record={phase='generation_claimed'};return {kind='unconfirmed',attempted=true} end
    w.record={phase='response_received',result=w.status or 'ready'}
    return {kind=w.record.result,attempted=true}
end}
function store:state() return w.record end
function store:lookup() if not w.record then return nil end;w.record.same=not w.stale_record;return w.record end
function store:discard_stale_prepared() w.record=nil;w.stale_record=false;return true end
function store:rebase_confirmed() w.record={phase='mode_confirmed'};w.stale_record=false;return true end
function store:prepare(plan)
    assert(plan.owner=='123' and plan.book_id=='456' and plan.chapter_uid==7 and plan.grant_sha256==hash and plan.baseline_sha256==hash)
    w.record={phase='prepared'};return w.record
end
local Task=require('weread.lib.translation_generation_task')
local function run() return Task.run({}, {},selected,web,input,store,{is_current=function() return w.valid end}) end
local result=run()
assert(result.kind=='pending' and result.mode_attempted and result.generation_attempted and w.mode_calls==1 and w.generation_calls==1,
    'ready version without content was treated as available')
result=run();assert(result.kind=='pending' and w.mode_calls==1 and w.generation_calls==1,'finished operation was repeated')
reset();w.available_after_generation=true;result=run()
assert(result.kind=='available' and w.mode_calls==1 and w.generation_calls==1,'actual translated content was not recognized')
reset();w.available=true;result=run();assert(result.kind=='available' and w.mode_calls==0 and w.generation_calls==0,'existing text generated again')
reset();w.available_during_recheck=true;result=run();assert(result.kind=='available' and w.mode_calls==0,'newly available text generated again')
reset();w.changed_baseline=true;result=run();assert(result.kind=='unavailable' and not w.record and w.mode_calls==0,'changed baseline allowed a write')
reset();w.mode_unknown=true;result=run();assert(result.kind=='unconfirmed' and result.mode_attempted and w.generation_calls==0)
result=run();assert(result.kind=='unconfirmed' and w.mode_calls==1,'unknown mode was retried')
reset();w.generation_unknown=true;result=run();assert(result.kind=='unconfirmed' and result.generation_attempted)
result=run();assert(result.kind=='unconfirmed' and w.generation_calls==1,'unknown generation was retried')
reset();w.record={phase='prepared'};w.stale_record=true;result=run()
assert(result.kind=='pending' and w.mode_calls==1 and w.generation_calls==1,'stale unsent plan was not replaced')
reset();w.record={phase='mode_confirmed'};w.stale_record=true;result=run()
assert(result.kind=='pending' and w.mode_calls==0 and w.generation_calls==1,'confirmed mode was repeated or not resumed')
reset();w.record={phase='generation_claimed'};w.stale_record=true;result=run()
assert(result.kind=='unconfirmed' and w.mode_calls==0 and w.generation_calls==0,'unknown claimed generation was replaced')
reset();w.record={phase='response_received',result='pending'};w.stale_record=true;result=run()
assert(result.kind=='pending' and w.mode_calls==0 and w.generation_calls==0,'known pending result was repeated')
reset();w.record={phase='response_received',result='stopped_unavailable'};w.stale_record=true;result=run()
assert(result.kind=='stopped' and w.mode_calls==0 and w.generation_calls==0,'known stopped result was repeated')
reset();w.error_after_mode=true;result=run();assert(result.kind=='unconfirmed' and result.mode_attempted,'exception after dispatch reported as safe')
reset();w.valid=false;result=run();assert(result.kind=='unavailable' and w.source_calls==0,'changed session performed preflight')
reset();web.web.cookies.wr_vid='999';result=run();assert(result.kind=='unavailable' and w.source_calls==0,'different Web account performed preflight')
print('PASS: combined translation task, independent result and no-replay behavior')

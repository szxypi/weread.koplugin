package.path='./?.lua;./?/init.lua;'..package.path
local helper=require('spec.helpers.annotation_test_store')
local Json=require('json')
local codec={json_encode=function(_self,v) return Json.encode(v) end,json_decode=function(_self,v) return Json.decode(v) end}
local Journal=require('weread.lib.translation_generation_journal')
local paths={os.tmpname(),os.tmpname()}
local account,valid='a',true
local library={settings={auth_scope_matches=function(_self,scope) return valid and scope.vid==(account=='a' and '123' or '124') end},
    accountKey=function() return account end,open=function() return helper.connect(paths[account=='a' and 1 or 2]) end}
local scope={vid='123',epoch=1}
local journal=Journal:new(library,codec,scope)
local wire={http_status=200,body_truncated=false}
local hash=string.rep('a',64)
local plan={owner='123',book_id='456',chapter_uid=7,book_version=2,translate_version=0,
    grant_sha256=hash,catalog_sha256=hash,source_sha256=hash,baseline_sha256=hash}
assert(journal:prepare(plan).phase=='prepared')
assert(not journal:prepare(plan) and not journal:claim_generation(plan),'unprepared operation bypassed the plan')
assert(journal:claim_mode(plan).phase=='mode_claimed')
assert(not journal:claim_mode(plan) and not journal:record_mode(plan,{}) and not journal:claim_generation(plan),
    'unknown mode result was retried or accepted')
local reopened=Journal:new(library,codec,scope)
assert(reopened:state(plan).phase=='mode_claimed' and not reopened:claim_mode(plan),'restart replayed a mode claim')
assert(not reopened:record_mode(plan,{succ=1},{http_status=500,body_truncated=false})
    and not reopened:record_mode(plan,{succ=1},{http_status=200,body_truncated=true}),
    'failed or truncated HTTP response accepted')
assert(reopened:record_mode(plan,{succ=1,bookId='456'},wire).phase=='mode_confirmed')
assert(reopened:claim_generation(plan).phase=='generation_claimed')
assert(not reopened:claim_generation(plan) and not reopened:record_status(plan,{stopPoll='unknown'}),
    'unknown generation result was retried or accepted')
assert(reopened:record_status(plan,{stopPoll=1,curStatus={{uid=7,translateVersion=1}}},wire).result=='ready')
assert(not reopened:claim_generation(plan) and not reopened:record_status(plan,{stopPoll=1}),
    'completed operation was replayed or overwritten')
local changed={};for k,v in pairs(plan) do changed[k]=v end;changed.source_sha256=string.rep('b',64)
assert(not reopened:state(changed) and not reopened:prepare(changed),'changed source replaced a consumed chapter')
local function chapter(uid)
    local result={};for k,v in pairs(plan) do result[k]=v end;result.chapter_uid=uid;return result
end
local pending=chapter(8);assert(reopened:prepare(pending))
local original_open=library.open
library.open=function()
    local db=original_open();local execute=db.exec
    db.exec=function(self,sql) if sql=='COMMIT' then error('synthetic commit failure') end;return execute(self,sql) end
    return db
end
assert(not reopened:claim_mode(pending),'failed commit allowed dispatch')
library.open=original_open
assert(reopened:state(pending).phase=='prepared','failed commit did not roll back')
assert(reopened:claim_mode(pending),'claim did not recover after a rolled-back commit')
local interrupted=chapter(9);assert(reopened:prepare(interrupted))
library.open=function()
    local db=original_open();local execute=db.exec
    db.exec=function(self,sql) local result=execute(self,sql);if sql=='COMMIT' then valid=false end;return result end
    return db
end
assert(not reopened:claim_mode(interrupted),'session change after commit allowed dispatch')
library.open=original_open;valid=true
assert(reopened:state(interrupted).phase=='mode_claimed' and not reopened:claim_mode(interrupted),
    'committed claim after session change was replayed')
valid=false;assert(not reopened:state(plan),'changed login retained access');valid=true
account='b';assert(not reopened:state(plan),'another account retained access')
local other={};for k,v in pairs(plan) do other[k]=v end;other.owner='124'
assert(Journal:new(library,codec,{vid='124'}):prepare(other),'another account inherited the first account claim')
for _,path in ipairs(paths) do os.remove(path);os.remove(path..'-wal');os.remove(path..'-shm') end
print('PASS: translation generation durable claims, restart and account isolation')

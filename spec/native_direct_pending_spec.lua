-- Exercise the real SQLite database, including account and transaction guards.
package.path='./?.lua;'..package.path
local helper=require('spec.helpers.annotation_test_store')
local Crypto=require('weread.lib.crypto')
local Store=require('weread.lib.native_direct_pending')
local scope={vid='123',epoch=1};local active=scope
local owner=require('weread.lib.native_position_contract').account_key(scope.vid)
local path=os.tmpname()
local library={accountKey=function() return owner end,open=function() return helper.connect(path) end,
    openRead=function() return helper.connect(path) end}
local settings={auth_scope_matches=function(_,value) return value==active end}
local entry={owner=Crypto.sha256_hex('native-direct-account\0'..scope.vid),book_id='42',chapter_uid='12',
    book_version=7,chapter_idx=1,title='Fixture',missing_images=0,text_digest=string.rep('b',64),
    source_sha256=string.rep('c',64),key=string.rep('d',64),copy=0,file_id=string.rep('a',64)}
local live=function() return true end
local function estimates(ids)
    local db=helper.connect(path)
    local values=Store.display_estimates(db,ids)
    db:close()
    return values
end
assert(not Store.read(library,settings,scope,entry,live))
assert(next(estimates({'42'}))==nil,'an old database required an estimate table')
assert(Store.save(library,settings,scope,entry,'/body/p.2',live,nil,23.5))
local first=assert(Store.read(library,settings,scope,entry,live));assert(first.xpointer=='/body/p.2')
assert(estimates({'42'})['42']==23.5 and next(estimates({'43'}))==nil,'estimate was shown for the wrong book')
local cache=require('weread.lib.native_direct_cache');local original_open=cache.open
cache.open=function() return {file_id=entry.file_id} end
local listed={entry};assert(Store.mark(library,settings,scope,'42',listed,live) and entry.pending_offline==true,
    'verified saved chapter did not show its offline reminder')
entry.pending_offline=nil;cache.open=function() return {file_id=string.rep('e',64)} end
assert(Store.mark(library,settings,scope,'42',listed,live) and not entry.pending_offline,
    'changed saved file was given a reminder')
cache.open=original_open
assert(Store.save(library,settings,scope,entry,'/body/p.4',live,first))
assert(next(estimates({'42'}))==nil,'a replacement without a catalog kept the old estimate')
local replaced=assert(Store.read(library,settings,scope,entry,live))
assert(Store.save(library,settings,scope,entry,'/body/p.5',live,replaced,25))
assert(not Store.save(library,settings,scope,entry,'/body/stale',live,first),
    'stale reminder overwrote a newer position')
assert(not Store.save(library,settings,scope,entry,'/body/unobserved',live),
    'unobserved existing reminder was overwritten')
local mismatched={};for key,value in pairs(first) do mismatched[key]=value end;mismatched.book_id='43';mismatched.xpointer='/body/p.5'
assert(not Store.save(library,settings,scope,entry,'/body/wrong-book',live,mismatched),
    'snapshot from another book overwrote the reminder')
assert(not Store.remove(library,settings,scope,entry,first,live),'old reminder deleted a newer one')
assert(estimates({'42'})['42']==25,'a stale update changed the displayed estimate')
assert(assert(Store.read(library,settings,scope,entry,live)).xpointer=='/body/p.5')
local calls=0
local latest=assert(Store.read(library,settings,scope,entry,live))
assert(not Store.save(library,settings,scope,entry,'/body/p.6',function() calls=calls+1;return calls<3 end,latest),
    'changed session committed a reminder')
assert(assert(Store.read(library,settings,scope,entry,live)).xpointer=='/body/p.5')
active={vid='456',epoch=2}
assert(not Store.read(library,settings,scope,entry,live) and not Store.save(library,settings,scope,entry,'x',live),
    'changed account accessed a reminder')
active=scope
local db=helper.connect(path);db:exec('BEGIN IMMEDIATE')
assert(not Store.save(library,settings,scope,entry,'x',live,latest),'concurrent writer was ignored')
db:exec('ROLLBACK');db:close()
local new=assert(Store.read(library,settings,scope,entry,live));assert(Store.remove(library,settings,scope,entry,new,live))
assert(not Store.read(library,settings,scope,entry,live),'confirmed reminder not removed')
assert(next(estimates({'42'}))==nil,'removing the reminder kept its estimate')
assert(not Store.save(library,settings,scope,entry,'bad\nanchor',live),'invalid pointer saved')
assert(Store.save(library,settings,scope,entry,'/valid',live))
db=helper.connect(path)
local insert=db:prepare('INSERT INTO native_direct_offline_pending VALUES(?,?,?,?,?,?,?,?)')
for i=1,Store.MAX_RECORDS-1 do
    insert:bind(string.format('%064x',i),'42','12',7,entry.source_sha256,entry.key,0,'/valid'):step();insert:reset()
end
insert:close();db:close()
local another={};for key,value in pairs(entry) do another[key]=value end;another.file_id=string.rep('e',64)
assert(not Store.save(library,settings,scope,another,'/new',live),'full quota silently evicted an offline reminder')
latest=assert(Store.read(library,settings,scope,entry,live))
assert(Store.save(library,settings,scope,entry,'/updated',live,latest),'full quota prevented updating the same reminder')
db=helper.connect(path);db:exec("UPDATE native_direct_offline_pending SET chapter_uid='99'");db:close()
assert(not Store.read(library,settings,scope,entry,live) and not Store.save(library,settings,scope,entry,'/other',live),
    'different identity was accepted or overwritten')
do
    local reader=helper.connect(path)
    reader:exec('BEGIN;DELETE FROM native_direct_offline_pending;DELETE FROM native_direct_offline_display;')
    local pending=reader:prepare('INSERT INTO native_direct_offline_pending VALUES(?,?,?,?,?,?,?,?)')
    local display=reader:prepare('INSERT INTO native_direct_offline_display VALUES(?,?,?,?)')
    local ids={}
    for index=1,Store.MAX_RECORDS do
        local book_id=tostring(900000+index)
        local file_id=string.format('%064x',index)
        pending:reset():bind(file_id,index==3 and '1' or book_id,'12',7,entry.source_sha256,entry.key,0,'/p'):step()
        display:reset():bind(book_id,file_id,index==2 and '/past-page' or '/p',index==4 and 101 or 25):step()
        ids[index]=book_id
    end
    pending:close();display:close();reader:exec('COMMIT')
    local seen=0
    local prepare=reader.prepare
    function reader:prepare(sql)
        local stmt=prepare(self,sql)
        if sql:find('JOIN native_direct_offline_pending',1,true) then
            local step=stmt.step
            stmt.step=function(statement)
                local row=step(statement)
                if row then seen=seen+1 end
                return row
            end
        end
        return stmt
    end
    local page={'900001','900002','900003','900004','900005','900110','missing','900110'}
    local visible=Store.display_estimates(reader,page)
    assert(seen==4,'visible lookup read unrelated database rows or repeated a requested book')
    assert(visible['900001']==25 and visible['900005']==25 and visible['900110']==25
        and not visible['900002'] and not visible['900003'] and not visible['900004'],
        'visible lookup accepted a stale pointer, the wrong book or an invalid percent')
    local all=Store.display_estimates(reader,ids)
    for _,id in ipairs(page) do assert(all[id]==visible[id],'page estimate differed from the full shelf result') end
    assert(all['900256']==25 and Store.display_estimates(reader,{})['900256']==nil)
    reader:close()
end
os.remove(path);os.remove(path..'-wal');os.remove(path..'-shm')
print('PASS: native offline reminders preserve account, identity, transaction and newer-position guards')

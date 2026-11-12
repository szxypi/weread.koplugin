package.path='./?.lua;'..package.path
local Dispatch=require('weread.lib.source_dispatch')
local checks=0
local function expect(value,message) checks=checks+1; assert(value,message or ('check '..checks)) end
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local values={account={user_vid='123'},books={['900001']={book_id='900001'}}}
local settings={get=function(_self,key,default) return copy(values[key] or default) end,
    set=function(_self,key,value) values[key]=copy(value) end,flush=function() end}
local serial=0
local function new()
    return Dispatch:new{settings=settings,now=function() return 100 end,
        nonce=function() serial=serial+1;return string.format('%032x',serial) end}
end
local journal=new()
local point={book_id='900001',chapter_uid='11',chapter_offset=4000,basis='filtered_xhtml_utf16',upload_verified=false,
    file_id=string.rep('a',64),raw_sha256=string.rep('b',64),book_version=1,render_path='chapter.xhtml',summary='SOURCE_TEXT_CANARY'}
local wire={book_id='900001',chapter_uid='11',chapter_idx=0,chapter_offset=4000,percent=37,summary='SOURCE_TEXT_CANARY'}
local function begin(kind) return journal:begin('900001',wire,point,kind or 'position') end
expect(not journal:pending('900001'))
local first=assert(begin())
expect(journal:pending('900001') and journal:owns(first),'journal not durable before returning receipt')
expect(not begin(),'unresolved dispatch was replaced')
local record=values.books['900001'].source_dispatch
expect(record.schema==1 and record.kind=='position' and record.started_at==100)
expect(not record.position.summary and not record.source_position.summary and not record.cookies,'text or credentials entered journal')
journal=new()
expect(journal:pending('900001') and journal:owns(first),'fresh instance lost interrupted dispatch')
expect(journal:finish(first,{acknowledged=true}) and journal:pending('900001'),'ACK alone cleared uncertainty')
expect(journal:finish(first,nil) and journal:pending('900001'),'missing child result cleared uncertainty')
expect(journal:finish(first,{enter_attempted=true,report_attempted=false}) and journal:pending('900001'),'possible enter was treated as unsent')
expect(journal:finish(first,{acknowledged=true,position_confirmed=true}) and not journal:pending('900001'))
local second=assert(begin('time'))
expect(not journal:finish(first,{acknowledged=true,position_confirmed=true}) and journal:owns(second),'late ACK cleared newer dispatch')
expect(journal:finish(second,{enter_attempted=false,report_attempted=false}) and not journal:pending('900001'),'proven unsent dispatch stayed blocked')
second=assert(begin())
values.account.user_vid='456'
expect(not journal:owns(second) and not journal:resolve('900001'),'different account cleared journal')
local third=assert(begin())
values.account.user_vid='123'
expect(not journal:finish(second,{acknowledged=true,position_confirmed=true}),'old account receipt erased replacement')
values.account.user_vid='456'
expect(journal:owns(third) and journal:resolve('900001') and not journal:pending('900001'))
values.books['900001'].source_dispatch='corrupt'
expect(journal:pending('900001') and not begin(),'malformed journal silently enabled writes')
expect(journal:resolve('900001') and not journal:pending('900001'),'explicit comparison could not retire malformed journal')
settings.set=function() error('fixture storage unavailable') end
expect(not begin() and not journal:pending('900001'),'persistence failure returned a send receipt')
settings.set=function(_self,key,value) values[key]=copy(value) end
settings.flush=function() error('fixture flush failed') end
expect(not begin() and journal:pending('900001'),'failed flush neither blocked send nor retained uncertainty')
settings.flush=function() end
journal:resolve('900001')
settings.get_auth_scope=function() return {} end
settings.auth_scope_matches=function() return false end
expect(not begin(),'stale disk account dispatched')
local epoch=1
settings.get_auth_scope=function() return {epoch=epoch} end
settings.auth_scope_matches=function() return true end
local old_session=assert(begin());epoch=2
expect(not journal:finish(old_session,{acknowledged=true,position_confirmed=true}) and journal:pending('900001'),
    'same-account login accepted an earlier session receipt')
expect(journal:resolve('900001'),'new session could not explicitly resolve old uncertainty')
print(('source_dispatch_spec: %d checks'):format(checks))

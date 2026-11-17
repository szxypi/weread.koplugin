package.path='./?.lua;'..package.path
package.preload['luasettings']=function() return {} end
local Service=require('weread.lib.shelf_membership_service')
local Task=require('weread.lib.shelf_membership_write')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local id='MP_WXS_42'
local function shelf(present,changed)
    local books={{bookId='41',title='Other',secret=changed and 1 or 0}}
    if present then books[#books+1]={bookId=id,title='Account'} end
    return {books=books,archive={{archiveId='7',name='Group',bookIds={'41'}}}}
end
local function fixture()
    local f={record={phase='idle',revision=0},jobs={},valid=true,revision=1}
    local grant={vid='900000',accessToken='synthetic-access'}
    local settings={get_auth_scope=function() return {vid='900000',epoch=1} end,auth_scope_matches=function() return f.valid end}
    local store={read=function() return grant,f.revision,nil,false end}
    local journal={read=function() return f.record end,
        begin=function(_self,_scope,target,operation) f.record={phase='pending',revision=f.record.revision+1,book_id=target,operation=operation};return f.record end,
        owns=function(_self,_scope,value) return value==f.record end,
        finish=function(_self,_scope,value) if value~=f.record then return false end;f.record={phase='idle',revision=value.revision+1};return true end}
    local worker={start=function(_self,task,callback) f.jobs[#f.jobs+1]={task=task,callback=callback};return true end,cancel=function() end}
    Task.fetch=function() return shelf(false,false) end
    Task.run=function(_client,_settings,_access,input,owns)
        expect(owns() and input.book_id==id and type(input.protected_digest)=='string','protected account plan missing')
        return {book_id=id,operation='add',attempted=true,confirmed=true,acknowledged=true,kind='confirmed',snapshot=shelf(true,false)}
    end
    f.service=Service:new{settings=settings,client={},scheduler={},journal=journal,store=store,worker=worker}
    function f.prepare() return f.service:prepare(id,function() return f.valid end,function(plan,reason) f.plan,f.reason=plan,reason end) end
    function f.deliver(value) local job=f.jobs[#f.jobs];job.callback(value or job.task()) end
    function f.commit() return f.service:commit(f.plan,function(result,finished) f.result,f.finished=result,finished end) end
    return f
end
local f=fixture();expect(f.prepare(),'account preview did not start');f.deliver();expect(f.plan and f.commit(),'account action did not reserve')
f.deliver();expect(f.finished and f.record.phase=='idle','matching account result did not settle')
f=fixture();f.prepare();f.deliver();f.commit()
f.deliver({book_id=id,operation='add',attempted=true,confirmed=true,acknowledged=true,kind='confirmed',snapshot=shelf(true,true)})
expect(not f.finished and f.record.phase=='pending','foreign flag change cleared account journal')
f=fixture();f.prepare();f.deliver();f.commit();f.revision=2
f.deliver({book_id=id,operation='add',attempted=true,confirmed=true,acknowledged=true,kind='confirmed',snapshot=shelf(true,false)})
expect(not f.finished and f.record.phase=='pending','stale grant cleared account journal')
print('PASS: public-account membership service ('..checks..' checks)')

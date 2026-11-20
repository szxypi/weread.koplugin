package.path='./?.lua;'..package.path
local state
package.preload['weread.lib.native_read_access']=function() return {matches=function() return not state.stale end} end
package.preload['ffi/sha2']=function()
    local sha={};sha.sha1=function(value) return tostring(#value) end
    sha.hmac=function(_kind,key,value) return string.rep('a',40)..#key..#value end
    sha.sha256=function()
        if state.simulated_large then
            local size=0
            return function(value) if value then size=size+#value;return end;return tostring(size) end
        end
        local bytes={}
        return function(value) if value then bytes[#bytes+1]=value;return end;return table.concat(bytes) end
    end
    return sha
end
package.preload['socket']=function() return {sleep=function(delay)
    state.sleeps=state.sleeps+1;state.waited=state.waited+delay
    if state.cancel_at_sleep==state.sleeps then state.guard_changed=true end
end} end
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=function() return state.info end} end
package.preload['weread.lib.native_authorization']=function() return {new=function(_self,_client,options)
    return {_request=function(_auth,stage,_url,_body,_credentials,_timeout,dispatch)
        assert(options.is_current())
        if stage=='personal_upload_credential' then return {bucket='synthetic-12345',ObjectName='/synthetic/object',
            Response={ExpiredTime=os.time()+300,Credentials={TmpSecretId='synthetic-id',TmpSecretKey='synthetic-key',Token='synthetic-token'}}} end
        assert(stage=='personal_upload_notify');if dispatch then dispatch() end;state.notifies=state.notifies+1
        if state.notify_lost then error('private error',0) end
        if state.notify_conflict then return {status=1,bookId='CB_synthetic42',errcode=0,errCode=-1} end
        return {status=1,bookId='CB_synthetic42'}
    end,cancel=function() end}
end} end
local Task=require('weread.lib.personal_upload')
Task.open_file=function(input)
    if state.simulated_large then
        local remaining=input.size;local chunk=string.rep('x',65536)
        return {read=function() if remaining<=0 then return nil end;local n=math.min(remaining,#chunk);remaining=remaining-n;return chunk:sub(1,n) end,
            seek=function() remaining=input.size;return 0 end,close=function() end}
    end
    return io.open(input.path,'rb')
end
local Members=require('weread.lib.shelf_membership_write')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local path=os.tmpname()..'.txt'
local function write(value) local file=assert(io.open(path,'wb'));assert(file:write(value));file:close() end
local function shelf(present,changed)
    local books={{bookId='41',title='Other',secret=changed and 1 or 0}}
    if present then books[#books+1]={bookId='CB_synthetic42',title='Synthetic file'} end
    return {books=books,archive={}}
end
local function fixture()
    state={info={mode='file',dev=1,ino=2,size=8,modification=1,change=1},requests=0,notifies=0,reads=0,sleeps=0,waited=0}
    write('abcdefgh')
    local input=assert(Task.capture(path));local selected={scope={vid='900000'},credentials={vid='900000'},renewal_pending=false}
    local journal={owns=function() return not state.journal_changed end}
    local empty={};local client={json_decode=function(_self,value) assert(value=='{}');return empty end,
        json_encode=function(_self,value) assert(value==empty);return '{}' end,
        request=function(_self,opts)
            state.requests=state.requests+1
            expect(opts.method=='PUT' and opts.skip_cookie and opts.persist_response_cookies==false and opts.sensitive,'COS request leaked session')
            expect(opts.url=='https://synthetic-12345.cos.accelerate.myqcloud.com/synthetic/object' and not opts.headers.Cookie,'COS destination changed')
            if state.mutate then write('12345678') end
            if not state.skip_source then while opts.source() do end end
            if state.status then return nil,state.status end
            return nil,200
        end}
    Members.fetch=function()
        state.reads=state.reads+1
        return shelf(state.reads>(state.appear_after or 1),state.foreign and state.reads>1)
    end
    function state.run() return Task.run(client,{},selected,input,journal,{},function() return not state.guard_changed end) end
    return input
end
fixture();local result=state.run()
expect(result.kind=='confirmed' and result.put_attempted and result.notify_attempted and state.requests==1 and state.notifies==1,'verified upload failed')
fixture();state.mutate=true;result=state.run()
expect(result.kind=='unconfirmed' and result.put_attempted and not result.notify_attempted and state.notifies==0,'changed file reached notify')
fixture();state.skip_source=true;result=state.run()
expect(result.kind=='unconfirmed' and not result.notify_attempted and state.notifies==0,'short upload reached notify')
fixture();state.notify_lost=true;result=state.run()
expect(result.kind=='unconfirmed' and result.notify_attempted and state.requests==1 and state.notifies==1,'unknown notify was retried or confirmed')
fixture();state.notify_conflict=true;result=state.run()
expect(result.kind=='unconfirmed' and result.notify_attempted and state.notifies==1,'conflicting error response was confirmed')
fixture();state.foreign=true;result=state.run()
expect(result.kind=='unconfirmed' and state.notifies==1,'foreign shelf change was confirmed')
fixture();state.appear_after=7;result=state.run()
expect(result.kind=='confirmed' and state.reads==8 and state.requests==1 and state.notifies==1,'delayed import was not confirmed')
fixture();state.appear_after=100;result=state.run()
expect(result.kind=='unconfirmed' and state.reads==10 and state.waited==18 and state.requests==1 and state.notifies==1,'unavailable import was retried or waited without bound')
fixture();state.appear_after=100;state.cancel_at_sleep=3;result=state.run()
expect(result.kind=='unconfirmed' and state.reads==4 and state.requests==1 and state.notifies==1,'cancelled readback continued or resent')
fixture();state.simulated_large=true;state.info.size=100*1024*1024;state.appear_after=12
local delayed=assert(Task.capture(path));local delayed_selected={scope={vid='900000'},credentials={vid='900000'},renewal_pending=false}
local large_client={json_decode=function() return {} end,json_encode=function() return '{}' end,
    request=function(_self,opts) state.requests=state.requests+1;while opts.source() do end;return nil,200 end}
local large_journal={owns=function() return true end}
result=Task.run(large_client,{},delayed_selected,delayed,large_journal,{},function() return not state.guard_changed end)
expect(result.kind=='confirmed' and state.reads==13 and state.waited==33 and state.requests==1 and state.notifies==1,'large delayed import was not confirmed')
fixture();state.simulated_large=true;state.info.size=100*1024*1024;state.appear_after=100
delayed=assert(Task.capture(path))
result=Task.run(large_client,{},delayed_selected,delayed,large_journal,{},function() return not state.guard_changed end)
expect(result.kind=='unconfirmed' and state.reads==17 and state.waited==60 and state.requests==1 and state.notifies==1,'large readback was unbounded or resent')
fixture();state.stale=true;result=state.run()
expect(result.kind=='unavailable' and state.requests==0 and state.notifies==0,'stale account sent upload')
local input=fixture();state.info.size=9;expect(not Task.matches(input),'changed file identity accepted')
fixture();state.info.size=200*1024*1024;expect(Task.capture(path)~=nil,'maximum sized file was rejected')
state.info.size=200*1024*1024+1;expect(not Task.capture(path),'oversize file was accepted')
for _,bad in ipairs({path..'.exe','relative.txt',path..'/../unsafe.txt'}) do expect(not Task.capture(bad),'invalid file path accepted') end
os.remove(path)
print('PASS: bounded native personal upload ('..checks..' checks)')

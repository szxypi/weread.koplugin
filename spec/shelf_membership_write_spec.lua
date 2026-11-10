package.path='./?.lua;'..package.path
local waits=0;package.preload.socket=function() return {sleep=function() waits=waits+1 end} end
local Task=require('weread.lib.shelf_membership_write')
local Access=require('weread.lib.native_read_access')
local Auth=require('weread.lib.native_authorization')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function shelf(...)
    local books={};for _i,id in ipairs({...}) do books[#books+1]={bookId=id,title='Synthetic '..id} end
    return {books=books,archive={}}
end
local function fixture(queue,operation)
    local f={queue=queue,requests={},bodies={},valid=true,revision=1}
    local grant={vid='900000',accessToken='synthetic-access'}
    local store={read=function() return grant,f.revision,nil,false end}
    local settings={get_auth_scope=function() return {vid='900000',epoch=1} end,auth_scope_matches=function() return f.valid end}
    local response
    local client={json_encode=function(_self,body) f.bodies[#f.bodies+1]=body;return 'encoded' end,
        json_decode=function() if response.invalid then error('private JSON') end;return response.data or response end,
        request=function(_self,options)
            expect(options.skip_cookie and options.persist_response_cookies==false and options.sensitive,'membership request leaked shared Web state')
            expect(options.headers.vid=='900000' and options.headers.accessToken=='synthetic-access' and not options.headers.Cookie,'captured owner/grant lost')
            f.requests[#f.requests+1]=options;response=assert(table.remove(f.queue,1),'missing fixture response')
            if response.raise then error('private transport') end
            return response.raw or 'fixture',response.status or 200,{}
        end}
    f.selected=Access.capture(settings,store);f.client,f.settings=client,settings
    local base=shelf('41');local members=Task.members(base)
    f.plan={book_id='42',operation=operation or 'add',before=false,members=members,members_digest=Task.digest(members)}
    if operation=='remove' then
        base=shelf('41','42');f.plan.before=true;f.plan.members=Task.members(base);f.plan.members_digest=Task.digest(f.plan.members)
    end
    function f.run(owns) return Task.run(client,settings,f.selected,f.plan,owns or function() return true end) end
    return f
end
local f=fixture({shelf('41'),{succ=1},shelf('41','42')});local r=f.run()
expect(r.kind=='confirmed' and r.confirmed and r.attempted and #f.requests==3,'confirmed add did not use one preflight, POST and GET')
expect(f.requests[2].url=='https://i.weread.qq.com/shelf/add' and f.requests[2].method=='POST'
    and #f.bodies[1].bookIds==1 and f.bodies[1].bookIds[1]=='42','wrong native add body')
f=fixture({shelf('41','42'),{succ=true},shelf('41')},'remove');r=f.run()
expect(r.confirmed and f.requests[2].url=='https://i.weread.qq.com/shelf/delete','remove protocol differs from validated Python')
f=fixture({shelf('41','42')});r=f.run();expect(r.kind=='noop' and not r.attempted and #f.requests==1,'already-desired membership posted again')
f=fixture({shelf('41','43')});r=f.run();expect(r.kind=='changed' and not r.attempted and #f.requests==1,'unrelated preflight change was overwritten')
f=fixture({shelf('41')});r=f.run(function() return false end);expect(not r.attempted and r.kind=='unavailable','revoked journal allowed POST')
for _i,reply in ipairs({{}, {succ=0}, {succ='1'}, {success=true}, {succ=1,success=false}, {succ=1,errcode=0,errCode=-1}, {raise=true}, {status=401}, {status=429}}) do
    f=fixture({shelf('41'),reply,shelf('41','42')});r=f.run()
    expect(r.attempted and not r.confirmed and r.kind=='unconfirmed' and #f.requests==3,'unknown/rejected write was accepted or replayed')
end
f=fixture({shelf('41'),{succ=1},shelf('41'),shelf('41'),shelf('41')});r=f.run()
expect(not r.confirmed and #f.requests==5 and waits>=2,'stale readback was unbounded or treated as success')
f=fixture({shelf('41'),{succ=1},shelf('41','42','43')});r=f.run()
expect(not r.confirmed and r.acknowledged and #f.requests==3,'unrelated post-write membership change was silently confirmed')
for _i,reply in ipairs({{books={{bookId='41',title='One'},{bookId='41',title='Duplicate'}}},{books={}},
    {status=401},{status=429},{invalid=true},{raw=string.rep('x',4*1024*1024+1)}}) do
    f=fixture({reply});r=f.run()
    if reply.books and #reply.books==0 then expect(r.kind=='changed' and not r.attempted,'empty shelf was not a changed preflight')
    else expect(r.kind=='unavailable' and not r.attempted and #f.requests==1,'invalid/preflight rejection attempted a write') end
end
f=fixture({})
local auth=Auth:new(f.client,{expected_vid='900000'})
for _i,id in ipairs({'MP_1','0','42/other',string.rep('1',21)}) do
    expect(not pcall(auth.write_shelf_membership,auth,f.selected.credentials,id,'add') and #f.requests==0,'nonordinary target reached HTTP')
end
expect(not pcall(auth.write_shelf_membership,auth,f.selected.credentials,'42','finish') and #f.requests==0,'unverified markstatus API was exposed')
print(('shelf_membership_write_spec: %d checks'):format(checks))

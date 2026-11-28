package.path='./?.lua;'..package.path
local Auth=require('weread.lib.web_authorization')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local owner={vid='123',epoch=2}
local function snapshot()
    return Auth.snapshot({cookies={wr_vid='123',wr_skey='XXXinitial',wr_rt='XXXrefresh',ignored='not sent'},
        wr_ticket='old-ticket',wr_wrpa='old-protection'},owner)
end
local original=snapshot();expect(#original.revision==64 and not original.cookies.ignored,'snapshot not whitelisted')
for _,values in ipairs({{cookies={wr_vid='124',wr_skey='XXXinitial'}},{cookies={wr_vid='123',wr_skey='short'}},
    {cookies={wr_vid='123',wr_skey='space token'}},{cookies={wr_vid='123',wr_skey='XXXinitial'},wr_ticket=false},
    {cookies={wr_vid='123',wr_skey='XXXinitial'},wr_wrpa='line\nbreak'}}) do expect(not pcall(Auth.snapshot,values,owner),'invalid authorization accepted') end
local result=Auth.receipt(original,{succ=1},{['Set-Cookie']={'wr_skey=XXXrenewed; Path=/; Secure','wr_ql=; Path=/'},['X-Wr-Ticket']='new-ticket'})
expect(result.cookies.wr_skey=='XXXrenewed' and result.cookies.wr_rt=='XXXrefresh' and not result.cookies.wr_ql
    and result.wr_ticket=='new-ticket' and result.wr_wrpa=='old-protection','receipt merge omitted/rotated fields wrong')
expect(original.cookies.wr_skey=='XXXinitial' and result.revision~=original.revision,'receipt mutated baseline')
for _,value in ipairs({{}, {succ=0}, {succ=false}}) do expect(not pcall(Auth.receipt,original,value,{}),'unconfirmed receipt accepted') end
expect(not pcall(Auth.receipt,original,{succ=1},{['set-cookie']='wr_vid=999; Path=/'}),'cross-account receipt accepted')
local state,client
local mt={}
local function fixture()
    state={requests={},responses={},headers={}}
    client={json_encode=function(_self,data)
        expect(data.rq=='%2Fweb%2Fbook%2Fread' and data.ql==false,'unverified POST body')
        return '{"rq":"%2Fweb%2Fbook%2Fread","ql":false}'
    end,json_decode=function(_self,text)
        if text=='[]' then return setmetatable({},mt) end
        local item=state.responses[text];assert(item,'unknown response');return item
    end,request=function(_self,opts)
        state.requests[#state.requests+1]=opts
        local n=#state.requests
        expect(opts.skip_cookie and opts.persist_response_cookies==false and opts.sensitive and not opts.headers.Authorization,'request used mutable/Bearer authentication')
        expect(opts.url:match('^https://weread%.qq%.com/'),'unrelated host')
        if n==1 and opts.method=='POST' then
            expect(opts.url=='https://weread.qq.com/web/login/renewal' and opts.body and opts.headers.Origin=='https://weread.qq.com','renewal route/body missing')
        else expect(opts.method=='GET' and not opts.body,'verification wrote account data') end
        local data=opts.url:find('/web/login/renewal',1,true) and {succ=1}
            or opts.url:find('/web/shelf/sync',1,true) and {books={{bookId='synthetic'}}} or {vid=123}
        if state.wrong_owner and opts.url:find('/api/userInfo',1,true) then data={vid=999} end
        if state.invalid_owner and opts.url:find('/api/userInfo',1,true) then data={vid=false,userVid=123} end
        if state.bad_books and opts.url:find('/web/shelf/sync',1,true) then data={books={}} end
        local text='response-'..n;state.responses[text]=data
        local headers=state.headers[n] or {}
        opts.sink(state.oversized and string.rep('x',65537) or text);opts.sink(nil)
        return nil,state.failure_at==n and 429 or 200,headers
    end}
end
fixture();state.headers[1]={['set-cookie']='wr_skey=XXXrenewed; Path=/'}
result=Auth.run(client,original)
expect(result.ok and result.attempted and result.book_count==1 and #state.requests==4 and result.candidate.cookies.wr_skey=='XXXrenewed','one renewal plus three verification reads failed')
expect(state.requests[2].headers.Cookie:find('wr_skey=XXXrenewed',1,true),'verification used old Cookie')
fixture();result=Auth.run(client,original,original);expect(result.ok and not result.attempted and #state.requests==3,'receipt verification replayed POST')
fixture();state.failure_at=1;result=Auth.run(client,original);expect(not result.ok and result.attempted and not result.candidate and #state.requests==1,'unknown POST receipt retried or confirmed')
fixture();state.failure_at=3;state.headers[2]={['set-cookie']='wr_skey=XXXrotated-read; Path=/'};result=Auth.run(client,original)
expect(not result.ok and result.candidate.cookies.wr_skey=='XXXrotated-read' and #state.requests==3,'verification failure lost confirmed same-owner rotation')
fixture();state.wrong_owner=true;result=Auth.run(client,snapshot());expect(not result.ok and result.candidate and #state.requests==2,'different profile was verified')
fixture();state.invalid_owner=true;result=Auth.run(client,snapshot());expect(not result.ok and result.candidate,'invalid primary owner silently used alternate field')
fixture();state.bad_books=true;result=Auth.run(client,snapshot());expect(not result.ok and result.candidate,'empty shelf object was treated as verified array')
fixture();state.oversized=true;result=Auth.run(client,snapshot())
expect(not result.ok and result.attempted and not result.candidate,'oversized receipt accepted')
print('PASS: Web renewal protocol, scoped receipts and verification ('..checks..' checks)')

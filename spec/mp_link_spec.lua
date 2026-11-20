package.path='./?.lua;'..package.path
local state={}
package.preload['weread.lib.native_read_access']=function() return {
    capture=function() return not state.no_access and {scope={vid='42'},credentials={vid='42'},renewal_pending=state.pending} end,
    matches=function() return not state.changed end} end
package.preload['weread.lib.read_access']=function() return {
    capture=function() return state.with_web and {web={cookies={wr_skey='XXX'}}} end,
    matches=function() return not state.web_changed end} end
package.preload['util']=function() return {htmlEntitiesToUtf8=function(text) return (text:gsub('&amp;','&')) end} end
package.preload['weread.lib.native_authorization']=function() return {new=function(_self,_client,options)
    assert(options.expected_vid=='42');return {_request=function(_auth,stage,url,body,credentials)
        assert(options.is_current() and stage=='mp_resolve' and url=='https://i.weread.qq.com/mp/getreviewid')
        assert(#body.urls==1 and body.urls[1]==state.url and credentials.vid=='42')
        state.requests=(state.requests or 0)+1
        if state.reason then error(state.reason,0) end
        return state.response
    end,cancel=function() state.cancelled=true end}
end} end
local M=require('weread.lib.mp_link')
local n=0
local function expect(value,label) n=n+1;assert(value,label) end
expect(M.MAX_RESULT>=65536 and M.MAX_RESULT<=8*1024*1024,'worker capacity invalid')
local short='https://mp.weixin.qq.com/s/synthetic_123'
local long='https://mp.weixin.qq.com/s?__biz=ABCDEFGH&mid=123&idx=1&sn='..string.rep('a',32)
expect(M.canonical(short..'?tracking=123#x')==short,'short canonicalization')
expect(M.canonical(long..'&tracking=1')==long,'long canonicalization')
for _,bad in ipairs({'http://mp.weixin.qq.com/s/synthetic_123','https://mp.weixin.qq.com.evil.test/s/synthetic_123',
    'https://mp.weixin.qq.com/s/short','https://mp.weixin.qq.com/s/synthetic_123/extra',long..'&mid=124',
    long:gsub('ABCDEFGH','%%ZZ'),long:gsub('idx=1','idx=0'),long:gsub('sn='..string.rep('a',32),'sn=bad')}) do
    expect(not M.canonical(bad),'unsafe URL accepted')
end
state.url=short
local row={url=short..'?tracking=1',reviewId='MP_WXS_42_synthetic_123',secret='discard'}
local projected=M.project(short,{reviewIds={row},secret='discard'})
expect(projected.book_id=='MP_WXS_42' and projected.review_id==row.reviewId and not projected.secret,'projection failed')
for _,bad in ipairs({{}, {reviewIds={}}, {reviewIds={row,row}}, {reviewIds={{url=short,reviewId='abc'}}},
    {reviewIds={{url='https://mp.weixin.qq.com/s/different_123',reviewId=row.reviewId}}},
    {reviewIds={{url=short,reviewId='MP_WXS_0_wrong'}}}}) do expect(not pcall(M.project,short,bad),'invalid result accepted') end
local input=assert(M.capture({},short));state.response={reviewIds={row}}
local result=M.read({}, {},input)
expect(result.ok and result.book_id=='MP_WXS_42' and result.review_id==row.reviewId and result.title=='' and state.requests==1 and state.cancelled,'lookup failed')
state.reason='native_auth/mp_resolve/http_401';result=M.read({}, {},input)
expect(result.kind=='login' and state.requests==2,'401 not classified')
state.reason='native_auth/mp_resolve/rejected';result=M.read({}, {},input)
expect(result.kind=='unavailable' and state.requests==3,'business rejection treated as login')
state.changed=true;result=M.read({}, {},input);expect(not result.ok and state.requests==3,'stale credential sent')
state.pending=true;expect(not M.capture({},short),'pending credential accepted')
state.no_access=true;expect(not M.capture({},short),'missing credential accepted')
state.changed=false;state.pending=false;state.no_access=false;state.reason=nil;state.with_web=true
input=assert(M.capture({},short))
local client={request=function(_self,opts)
    expect(opts.url=='https://weread.qq.com/web/mp/content?reviewId='..row.reviewId and opts.method=='GET'
        and opts.skip_cookie and opts.persist_response_cookies==false and opts.sensitive,'title request scope changed')
    opts.sink('<html><head><meta content="Title &amp; name" property="og:title"/></head></html>');return nil,200
end}
result=M.read(client,{},input);expect(result.ok and result.title=='Title & name','article title not decoded')
state.web_changed=true;local before=state.requests;result=M.read(client,{},input)
expect(not result.ok and state.requests==before,'stale web credentials sent')
expect(not M.title('bad\nvalue') and not M.extract_title('<meta property="og:title" content="bad\nvalue">'),'invalid title accepted')
print('PASS: native article link model ('..n..' checks)')

package.path='./?.lua;'..package.path
local state={}
package.preload['weread.lib.read_access']=function() return {capture=function() return not state.no_web and {web={cookies={wr_skey='XXX'}},revision='captured'} end,
    matches=function() return not state.changed end} end
local Model=require('weread.lib.mp_catalog')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    state={requests={},headers={wr_ticket='synthetic-ticket',wr_wrpa='synthetic-protection'}}
    local settings={get=function(_self,key,default) return state.headers[key] or default end}
    return settings,{book_id='MP_WXS_42'}
end
local function response()
    return {errCode=0,reviews={{subReviews={{reviewId='outer',private='discard',review={reviewId='inner',belongBookId='MP_WXS_42',createTime=1700000000,
        mpInfo={title='Article',originalId='original',pic_url='https://example.invalid/a',content_url='https://example.invalid/source'},private='discard'}}}}}}
end
local settings,book=fixture();local input=assert(Model.capture(settings,book))
state.headers.wr_ticket='replacement';expect(input.ticket=='synthetic-ticket' and not Model.matches(settings,input),'header snapshot mutable or stale')
settings,book=fixture();input=assert(Model.capture(settings,book));state.changed=true;expect(not Model.matches(settings,input),'changed access revision accepted')
for _,id in ipairs({'42','MP_WXS_0','MP_WXS_42/extra','MP_WXS_'..string.rep('9',21)}) do expect(not Model.capture(settings,{book_id=id}),'invalid account accepted') end
expect(not Model.capture(settings,{book_id='MP_WXS_42',bookId='MP_WXS_43'}),'contradictory account accepted')
state.no_web=true;expect(not Model.capture(settings,book),'gateway-only account accepted')
local page=Model.project(response(),'MP_WXS_42');local row=page.articles[1]
expect(page.ok and #page.articles==1 and row.reviewId=='inner' and #row.reviewIds==3 and row.reviewIds[1]=='outer','nested review normalization changed')
expect(not row.private and row.title=='Article' and row.createTime==1700000000 and row.originalId=='original','display fields lost or private fields retained')
local sample=response();sample.reviews[1].subReviews[1].review.reviewId=''
expect(Model.project(sample,'MP_WXS_42').articles[1].reviewId=='outer','empty inner ID blocked stable outer ID')
expect(#Model.project({reviews={}},'MP_WXS_42').articles==0,'valid empty page rejected')
for code,kind in pairs({[-2041]='verification',[-2012]='login',[-1]='unavailable'}) do
    page=Model.project({errCode=code,errmsg='private response'},'MP_WXS_42')
    expect(not page.ok and page.kind==kind and not page.errmsg and not page.articles,'business error projected as empty/sensitive result')
end
for _,bad in ipairs({{}, {reviews=false},{reviews={other=true}},{reviews={{}}},{reviews={{subReviews=false}}},
    {reviews={{subReviews={{review=false}}}}},{reviews={{subReviews={{reviewId='only',mpInfo=false}}}}},
    {errCode='-2041'}, {errCode=true},{errCode=false,reviews={}},{errCode='',reviews={}},{errCode=-2041,errcode=0},{reviews={{subReviews={{}}}}}}) do
    expect(not pcall(Model.project,bad,'MP_WXS_42'),'malformed page accepted')
end
for _,field in ipairs({'reviewId','title','reviewIds','createTime','bookId','pic_url','sourceUrl'}) do
    local rows={{reviewId='id',title='title',createTime=1}}
    rows[1][field]=false;expect(not pcall(Model.rows,rows,'MP_WXS_42'),'bad projected field accepted: '..field)
end
local rows={[1]={reviewId='a'},[3]={reviewId='c'}};expect(not pcall(Model.rows,rows,'MP_WXS_42'),'sparse rows silently truncated')
rows={};for index=1,101 do rows[index]={reviewId=tostring(index)} end;expect(not pcall(Model.rows,rows,'MP_WXS_42'),'row limit ignored')
settings,book=fixture();input=assert(Model.capture(settings,book));local raw=response()
local client={json_decode=function(_self,value) if value=='[]' then return {} end;return raw end,
    request=function(_self,opts)
        state.requests[#state.requests+1]=opts
        expect(opts.method=='GET' and opts.skip_cookie and opts.persist_response_cookies==false and opts.sensitive,'request mutated session')
        expect(opts.headers.Cookie=='wr_skey=XXX' and opts.headers['x-wr-ticket']=='synthetic-ticket' and opts.headers['x-wrpa-0']=='synthetic-protection','captured headers lost')
        expect(opts.url=='https://weread.qq.com/web/mp/articles?bookId=MP_WXS_42&maxIdx=0&count=100','unverified route/query used')
        if state.transport_failed then error('private transport detail') end
        opts.sink(state.body or '{}');return nil,state.status or 200
    end}
page=Model.read(client,input);expect(page.ok and #state.requests==1,'first-page GET repeated or failed')
raw={errCode=-2041};page=Model.read(client,input);expect(page.kind=='verification' and #state.requests==2,'verification rejection retried or cleared cache')
for _,code in ipairs({302,429,503,401}) do state.status=code;page=Model.read(client,input);expect(not page.ok and page.kind==(code==401 and 'login' or 'unavailable'),'HTTP failure treated as empty page') end
state.status=200;local maximum=Model.MAX_BYTES;Model.MAX_BYTES=1;expect(not pcall(Model.read,client,input),'response cap ignored');Model.MAX_BYTES=maximum
local array_mt={};client.json_decode=function(_self,value) if value=='[]' then return setmetatable({},array_mt) end;return {reviews={}} end
expect(not pcall(Model.read,client,input),'empty object accepted as valid empty reviews array')
client.json_decode=function(_self,value) if value=='[]' then return setmetatable({},array_mt) end;return {reviews=setmetatable({},array_mt)} end
expect(Model.read(client,input).ok,'typed empty array not accepted')
print('PASS: bounded readonly MP catalog ('..checks..' checks)')

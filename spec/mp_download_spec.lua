package.path='./?.lua;'..package.path
local state={}
package.preload['weread.lib.content']=function() return {
    book_resolved_dir=function(_settings,book_id,book) return book.cache_dir or '/cache/'..book_id end,
    extract_mp_body=function(text) return text:match('<div id="js_content">(.-)</div>') end,
    strip_mp_images=function(text) return (text:gsub('<img[^>]*>','')) end,
    render_mp_article_html=function(_article,text,key) return require('weread.lib.mp_cache_identity').marker(key)..text end} end
package.preload['weread.lib.read_access']=function() return {capture=function() return state.no_web and {} or {web={cookies={wr_skey='XXX'}}} end,
    matches=function() return not state.changed end} end
package.preload['weread.lib.notes_export_file']=function() return {create=function()
    if state.no_space then return nil end
    local file={path='/temporary',value=''}
    function file:write(bytes) self.value=self.value..bytes;return not state.write_failed end
    function file:sync() return not state.sync_failed end
    function file:accept(bytes) state.image_value=self.value;return #self.value==bytes end
    function file:abort() state.aborted=true end
    return file
end} end
package.preload['util']=function() return {htmlEntitiesToUtf8=function(s) return (s:gsub('&amp;','&')) end} end
local Model=require('weread.lib.mp_download')
local Stage=require('weread.lib.mp_download_stage')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    state={requests={},cache={download_mp_images=true},body='<p>Fixture</p><img src="//mmbiz.qpic.cn/x?a=1&amp;b=2"><img src="https://mmbiz.qpic.cn/x?a=1&amp;b=2">'}
    local settings={get=function(_self,key,default) if key=='cache' then return state.cache end;return default end}
    local book={book_id='MP_WXS_42'}
    local article={reviewId='one/two',reviewIds={'one/two','fallback'},title='Article'}
    local stage={directory='/stage',generation='.generation',key='key',output={write=function(_self,text) state.html=text;return not state.body_failed end,sync=function() return true end},images_owned=function() return not state.replaced end}
    local client={request=function(_self,opts)
        state.requests[#state.requests+1]=opts
        expect(opts.method=='GET' and opts.skip_cookie and opts.persist_response_cookies==false and opts.sensitive,'mutable or unsafe transport')
        if opts.diagnostic_api=='mp_read' then
            expect(opts.headers.Cookie=='wr_skey=XXX','captured cookie absent')
            if state.primary_missing and #state.requests==1 then opts.sink('');return nil,200 end
            opts.sink(state.raw_body or '<div id="js_content">'..state.body..'</div>');return nil,state.body_status or 200
        end
        expect(not opts.headers.Cookie and not opts.headers.Authorization and not opts.headers['x-wr-ticket'] and not opts.headers['x-wrpa-0'],'CDN received authentication')
        expect(opts.url=='https://mmbiz.qpic.cn/x?a=1&b=2','CDN URL not exact/decoded')
        opts.sink(state.image or '\137PNG\r\n\26\nfixture');opts.sink(nil);return nil,state.image_status or 200
    end}
    return settings,book,article,stage,client
end
local rename=os.rename;rawset(os,'rename',function() return not state.rename_failed end)
local settings,book,article,stage,client=fixture()
local input=assert(Model.capture(settings,book,article));article.title='changed';article.reviewIds[2]='changed'
expect(input.article.title=='Article' and input.ids[2]=='fallback','input not snapshotted')
local result=Model.write(client,input,stage,{missing='Unavailable'})
expect(result.ok and result.images==1 and #state.requests==2 and result.image_bytes==#state.image_value,'duplicates not streamed once')
expect(state.html:find('.generation/images/img-0001.png',1,true) and not state.html:find('https://',1,true),'remote image retained')
state.changed=true;expect(not Model.matches(settings,input),'changed account accepted')
for _,value in ipairs({'https://mmbiz.qpic.cn.evil/x','https://user@mmbiz.qpic.cn/x','https://mmbiz.qpic.cn:443/x','file:///x','https://mmbiz.qpic.cn/x y'}) do expect(not Model.image_url(value),'unsafe CDN URL accepted') end
expect(Model.image_url('http://mmbiz.qlogo.cn/x#fragment')=='https://mmbiz.qlogo.cn/x','HTTPS normalization failed')
for _,change in ipairs({'image_status','body_status','image','no_space','write_failed','sync_failed','rename_failed','body_failed','replaced'}) do
    settings,book,article,stage,client=fixture();input=assert(Model.capture(settings,book,article))
    if change=='image_status' then state[change]=302 elseif change=='body_status' then state[change]=403
    elseif change=='image' then state[change]='<html>verification</html>' else state[change]=true end
    expect(not pcall(Model.write,client,input,stage,{missing='Unavailable'}),'failed transaction accepted: '..change)
end
settings,book,article,stage,client=fixture();state.primary_missing=true;input=assert(Model.capture(settings,book,article))
result=Model.write(client,input,stage,{});expect(result.ok and #state.requests==3 and state.requests[2].url:find('fallback',1,true),'bounded fallback missing')
settings,book,article,stage,client=fixture();state.cache.download_mp_images=false;input=assert(Model.capture(settings,book,article))
result=Model.write(client,input,stage,{});expect(result.images==0 and #state.requests==1 and not state.html:find('<img',1,true),'images-off requested CDN')
settings,book,article,stage,client=fixture();state.body='<img src="file:///private"><style>p{background:url(https://evil)}</style><p onclick="evil()">kept</p>'
input=assert(Model.capture(settings,book,article));result=Model.write(client,input,stage,{missing='Unavailable'})
expect(result.missing==1 and #state.requests==1 and not state.html:find('onclick',1,true) and not state.html:find('file:',1,true),'passive conversion fetched local/untrusted resource')
for _,limit in ipairs({'MAX_HTML','MAX_IMAGE','MAX_TOTAL','MAX_IMAGES'}) do
    local maximum=Stage[limit];Stage[limit]=limit=='MAX_IMAGES' and 0 or 2
    settings,book,article,stage,client=fixture();input=assert(Model.capture(settings,book,article))
    expect(not pcall(Model.write,client,input,stage,{}),'capacity limit ignored: '..limit);Stage[limit]=maximum
end
for _,case in ipairs({{value={errCode=-2012},error='mp_download/login'},
    {value={errCode=-2041},error='mp_download/verification'},
    {value={errCode=0,errcode=-2012},error='mp_download/unavailable'}}) do
    settings,book,article,stage,client=fixture();state.raw_body='{"error":"synthetic"}'
    client.json_decode=function() return case.value end;input=assert(Model.capture(settings,book,article))
    local ok,reason=pcall(Model.write,client,input,stage,{})
    expect(not ok and reason==case.error and #state.requests==1,'body login/verification/conflicting code classification wrong')
end
for _,case in ipairs({{code=401,error='mp_download/login'},{code=429,error='mp_download/unavailable'}}) do
    settings,book,article,stage,client=fixture();state.body_status=case.code;input=assert(Model.capture(settings,book,article))
    local ok,reason=pcall(Model.write,client,input,stage,{})
    expect(not ok and reason==case.error and #state.requests==1,'HTTP login/throttle repeated before recovery')
end
settings,book,article=fixture();state.no_web=true;expect(not Model.capture(settings,book,article),'gateway alone accepted for Web article')
rawset(os,'rename',rename)
print('PASS: readonly MP background transport ('..checks..' checks)')

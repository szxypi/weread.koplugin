package.path='./?.lua;'..package.path
local Fetch=require('weread.lib.translation_fetch')
local Model=require('weread.lib.translation')
local Protocol=require('weread.lib.protocol')
local checks=0
local function expect(value,reason) checks=checks+1;assert(value,reason) end
local function analyze(text) return assert(Model.analyze('<html><body>'..text..'</body></html>','1',1,true)) end
local old=analyze('<h1>Title</h1><p>First <em>unique</em> paragraph.</p><p>Second unique paragraph.</p>')
local new=analyze('<h1>Title</h1><p>First <em>unique</em> paragraph.</p><p class="wr-translation">第一段</p><p>Second unique paragraph.</p><p class="wr-translation">第二段</p>')
expect(Model.refresh_target(old,new,'/body/DocFragment[4]/body/p[2]/text().3')=='/body/DocFragment[1]/body/p[3]','new sibling paths were not mapped')
expect(Model.refresh_target(old,new,'/body/DocFragment/body/p[1]/em/text().2')=='/body/DocFragment[1]/body/p[1]/em[1]','inline source block mapping wrong')
expect(not Model.refresh_target(old,new,'/body/DocFragment[4]/body/p[20]/text().0'),'prefix collision guessed a target')
local changed=analyze('<p>Changed paragraph.</p>')
expect(not Model.refresh_target(old,changed,'/body/DocFragment[4]/body/p[1]/text().3'),'changed original mapped')
local duplicate=analyze('<p>Same</p><p>Same</p>')
expect(not Model.refresh_target(duplicate,duplicate,'/body/DocFragment[1]/body/p[1]/text().0'),'duplicate source guessed a target')
expect(not Model.refresh_target(old,analyze('<p>Second unique paragraph.</p><p>Second unique paragraph.</p>'),'/body/DocFragment[1]/body/p[2]/text().1'),'duplicate destination guessed a target')
old.recoveries=1;expect(not Model.refresh_target(old,new,'/body/DocFragment[1]/body/p[1]/text().0'),'recovered markup migrated');old.recoveries=0
local calls,encoded,binary=0,{},{}
local client={json_decode=function(_self,value) return encoded[value] end,
    request=function(_self,options) calls=calls+1;expect(options.sensitive==true,'private read not sensitive');options.sink('bounded');return nil,200 end,
    get_binary=function(_self,url,options) binary[#binary+1]={url=url,options=options};return 'image' end}
local book={book_id='900001',psvts='synthetic'}
local proxy=Fetch.client(client,book,'1')
expect(proxy:request{url=Protocol.reader_url('900001'),method='GET'}=='bounded','reader result sink lost bytes')
encoded.catalog={bookIds={'900001'}}
proxy:request{url='https://weread.qq.com/web/book/chapterInfos',method='POST',body='catalog'}
for i=0,3 do
    encoded.shard=Protocol.make_content_params('900001','1','synthetic',{style=i==2})
    proxy:request{url='https://weread.qq.com/web/book/chapter/e_'..i,method='POST',body='shard'}
end
for _,case in ipairs({
    {'https://i.weread.qq.com/en/bookread','POST','catalog'},
    {'https://i.weread.qq.com/trans/pdfepub','GET'},
    {'https://weread.qq.com/web/book/read','POST','catalog'},
    {'https://weread.qq.com/web/login/renewal','POST','catalog'},
    {Protocol.reader_url('900002'),'GET'},
    {'https://weread.qq.com/web/book/chapter/t_0','POST','shard'},
    {'https://weread.qq.com/web/book/chapter/e_0?extra=1','POST','shard'},
}) do
    local before=calls
    expect(not pcall(proxy.request,proxy,{url=case[1],method=case[2],body=case[3]}) and calls==before,'out-of-scope request was dispatched')
end
for _,change in ipairs({'wrong_book','wrong_uid','extra','trial','old_clock','signature','style'}) do
    local value=Protocol.make_content_params('900001','1','synthetic')
    if change=='wrong_book' then value.b=Protocol.e('900002')
    elseif change=='wrong_uid' then value.c=Protocol.e('2')
    elseif change=='extra' then value.extra=1
    elseif change=='trial' then value.freeTrial=1
    elseif change=='old_clock' then value.ct=tostring(os.time()-100)
    elseif change=='signature' then value.s='wrong'
    else value.st=1 end
    encoded.bad=value
    expect(not pcall(proxy.request,proxy,{url='https://weread.qq.com/web/book/chapter/e_0',method='POST',body='bad'}),'modified shard admitted: '..change)
end
proxy:get_binary('https://cdn.weread.qq.com/synthetic.png')
expect(binary[1].options.skip_cookie and binary[1].options.persist_response_cookies==false and binary[1].options.max_bytes==4*1024*1024,'assets were not anonymous/bounded')
for _,url in ipairs({'https://weread.qq.com/web/book/read','https://example.invalid/image.png','http://cdn.weread.qq.com/image.png','https://cdn.weread.qq.com@evil.invalid/image.png'}) do
    expect(not pcall(proxy.get_binary,proxy,url),'foreign asset admitted')
end
expect(not pcall(binary[1].options.on_redirect,'https://cdn.weread.qq.com/a','https://example.invalid/b'),'foreign redirect admitted')
client.request=function(_self,options) options.sink(string.rep('x',6*1024*1024+1));return nil,200 end
expect(not pcall(proxy.request,proxy,{url=Protocol.reader_url('900001'),method='GET'}),'oversized response accepted')
print('translation_fetch_spec: '..checks..' checks')

-- Full backend flow with KOReader JSON/SQLite/EPUB and a synthetic service.
require('setupkoenv')
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(os.getenv('WEREAD_TEST_DIR'))
local Content=require('weread.lib.content')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Archive=require('weread.lib.source_archive')
local settings_scope={vid='123',epoch=1}
local cookies={wr_vid='123',wr_skey='synthetic-cookie'}
local settings={data_dir=root,cache_dir=root,get=function(_self,key,default)
    if key=='account' then return {user_vid='123'} elseif key=='cookies' then return cookies end
    return default
end,get_auth_scope=function() return settings_scope end,auth_scope_matches=function(_self,scope) return scope==settings_scope end}
local creds={vid='123',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId='eink3346912251234567890123456789'}
local store={read=function() return creds,1,nil,false end}
local selected=assert(require('weread.lib.native_read_access').capture(settings,store))
local web=assert(require('weread.lib.read_access').capture(settings))
local client=require('weread.lib.client'):new(settings)
local library=require('weread.lib.library_db'):new(settings)
local journal=require('weread.lib.translation_generation_journal'):new(library,client,settings_scope)
local task=require('weread.lib.translation_generation_task')
local raw='<html><body><p>'..string.rep('A synthetic original passage for generation. ',10)..'</p></body></html>'
local translated=raw:gsub('</p>','</p><p class="wr-translation">合成译文</p>')
local generated,fail_generation,baseline_counter=false,false,0
local mode_calls,generation_calls=0,0
local function fixture(id)
    local book={book_id=id,bookVersion=7,title='Synthetic '..id,cache_dir=root}
    local chapter={chapterUid=7,title='Chapter One',wordCount=400,price=0}
    local source=assert(Source.capture(book,chapter,raw,'web_xhtml'))
    local path=assert(Content.save_chapter_epub(settings,book,chapter,raw,nil,nil,Identity.capture(book),source))
    local values=assert(Archive.read(path,{[Identity.PATH]=Identity.MAX_BYTES,[Source.meta_path('7')]=Source.MAX_META_BYTES}))
    local identity=assert(Identity.decode(values[Identity.PATH]))
    return {book_id=id,chapter_uid='7',path=path,metadata=values[Source.meta_path('7')],file_id=identity.file_id}
end
local first=fixture('456');local second=fixture('457');local id=first.book_id
local original_file=assert(io.open(first.path,'rb'));local original=assert(original_file:read('*a'));original_file:close()
Content.ensure_reader_state=function() end
Content.fetch_catalog=function() return {{chapterUid=7,title='Chapter One',wordCount=400}},7 end
Content.fetch_chapter_xhtml=function(_client,_settings,book,chapter)
    local body=generated and translated or raw
    return body,assert(Source.capture(book,chapter,body,'web_xhtml'))
end
local function payload(value) return client:json_encode(value) end
client.request=function(self,request)
    local url=request.url
    assert(request.sensitive and request.sink)
    local response
    if url=='https://i.weread.qq.com/pay/memberCardSummary?pf=wechat_wx-2001-android-100-weread' then
        assert(request.method=='GET');response={isPaying=true}
    elseif url=='https://i.weread.qq.com/book/info?bookId='..id then
        assert(request.method=='GET');response={bookId=id,format='epub',version=7}
    elseif url=='https://i.weread.qq.com/book/chapterInfos' then
        local body=self:json_decode(request.body);assert(request.method=='POST' and body.bookIds[1]==id)
        response={data={{bookId=id,updated={{chapterUid=7,title='Chapter One',wordCount=400,price=0,translateVersion=generated and 1 or 0}}}}}
    elseif url=='https://i.weread.qq.com/book/getProgress?bookId='..id or url:match('^https://weread%.qq%.com/web/book/getProgress%?') then
        assert(request.method=='GET');response={bookId=id,book={bookId=id,title='Synthetic',readingTime=baseline_counter},canFreeRead=1,timestamp=100}
    elseif url=='https://i.weread.qq.com/shelf/sync' or url=='https://weread.qq.com/web/shelf/sync' then
        assert(request.method=='GET');response={books={{bookId=id,isTop=0,secret=0,finishReading=0}},archive=self:json_decode('[]')}
    elseif url:match('^https://i%.weread%.qq%.com/trans/pdfepub%?') then
        assert(request.method=='GET');mode_calls=mode_calls+1;response={succ=1}
    elseif url=='https://i.weread.qq.com/en/bookread' then
        assert(request.method=='POST');generation_calls=generation_calls+1
        local body=self:json_decode(request.body)
        assert(body.bookId==id and body.freeTrial==0 and #body.read==1 and body.read[1].uid==7 and self:json_encode(body.reference.texts)=='[]')
        if fail_generation then error('synthetic lost reply') end
        generated=true;response={stopPoll=1,curStatus={{uid=7,translateVersion=1}}}
    else error('unexpected synthetic endpoint') end
    assert(request.sink(payload(response)));return nil,200,{}
end
local options={is_current=function() return true end}
local stale_plan={owner='123',book_id='456',chapter_uid=7,book_version=7,translate_version=0,
    grant_sha256=selected.fingerprint,catalog_sha256=string.rep('a',64),source_sha256=string.rep('a',64),baseline_sha256=string.rep('a',64)}
assert(journal:prepare(stale_plan),'could not create old unsent plan')
local result=task.run(client,settings,selected,web,first,journal,options)
assert(result.kind=='available' and result.mode_attempted and result.generation_attempted and mode_calls==1 and generation_calls==1,
    'actual composed task did not discover the resulting translation')
result=task.run(client,settings,selected,web,first,journal,options)
assert(result.kind=='available' and mode_calls==1 and generation_calls==1,'already translated chapter was resubmitted')
local file=assert(io.open(first.path,'rb'));assert(file:read('*a')==original);file:close()
id=second.book_id;generated=false;fail_generation=true
result=task.run(client,settings,selected,web,second,journal,options)
assert(result.kind=='unconfirmed' and result.generation_attempted and mode_calls==2 and generation_calls==2,'lost response did not remain unknown')
baseline_counter=1
result=task.run(client,settings,selected,web,second,journal,options)
assert(result.kind=='unconfirmed' and mode_calls==2 and generation_calls==2,'lost response was replayed after the baseline changed')
print('PASS: KOReader combined translation workflow and no replay after lost reply')

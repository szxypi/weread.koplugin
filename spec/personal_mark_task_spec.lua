package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(s) return s:gsub('&amp;','&') end} end
local Fixture=require('spec.helpers.thought_edit_fixture')
local codec=Fixture.codec()
local saved={book_id='41',updated={},chapters={}}
local writes,fetches=0,0
package.preload['weread.lib.my_cloud_marks_store']=function() return {
    new=function() return {read=function() return saved end,write=function() writes=writes+1 end} end,
} end
local Marks=require('weread.lib.my_cloud_marks')
Marks.fetch=function(_client,book,options)
    fetches=fetches+1;assert(book=='41' and options.native.accessToken=='synthetic')
    if options.native.fail then error('private failure') end
    return {book_id=book,updated={},chapters={},fresh=true}
end
local Task=require('weread.lib.personal_mark_task')
local Crypto=require('weread.lib.crypto')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local offline=Task.load(codec,{},'41',nil,false)
expect(offline.snapshot==saved and not offline.refreshed and fetches==0)
local access={accessToken='synthetic',renewal_pending=true}
Task.load(codec,{},'41',access,true);expect(fetches==0,'pending renewal dispatched a request')
access.renewal_pending=false
local fresh=Task.load(codec,{},'41',access,true)
expect(fresh.refreshed and fresh.snapshot.fresh and fresh.previous==nil,'worker returned duplicate large snapshots')
access.fail=true
expect(Task.load(codec,{},'41',access,true).snapshot==saved,'network failure lost offline snapshot')
expect(fetches==2 and writes==0,'load wrote cache or retried authorization')
local raw='<html><body><p>Unique &amp; selected <b>text</b> content that remains intact.</p></body></html>'
local book,chapter={book_id='41',bookVersion=7},{chapterUid='2'}
local path='OEBPS/text/chapter.xhtml'
local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(raw))
local metadata=assert(Source.bind(assert(Source.capture(book,chapter,raw,'web_xhtml')),assert(Identity.decode(root)),path,Crypto.sha256_hex(raw)))
local members={[Identity.PATH]=root,[Source.meta_path('2')]=metadata,[Source.path_meta_path(path)]=metadata,
    [Source.raw_path(Crypto.sha256_hex(raw))]=raw,[path]=raw}
local reads=0
local function archive(file,wanted)
    reads=reads+1;assert(file=='/cached.epub');local result={}
    for name,limit in pairs(wanted) do if members[name] then assert(#members[name]<=limit);result[name]=members[name] end end
    return result
end
local row={bookmarkId='synthetic-own',type=1,chapterUid=2,markText='Unique & selected text',range='15-48'}
local result=Task.prepare('/cached.epub','41',metadata,{row},archive)
expect(#result.rows==1 and result.rows[1].bookmarkId==row.bookmarkId and reads==1)
expect(result.rows[1].raw==nil and result.rows[1].markText==nil,'private source leaked from worker')
expect(result.rows[1].first_anchor.co<result.rows[1].last_anchor.co,'both span boundaries were not prepared')
for _i,key in ipairs({Identity.PATH,Source.meta_path('2'),Source.path_meta_path(path),Source.raw_path(Crypto.sha256_hex(raw)),path}) do
    local previous=members[key];members[key]='changed'
    expect(not pcall(Task.prepare,'/cached.epub','41',metadata,{row},archive),'corrupt source member accepted')
    members[key]=previous
end
expect(not pcall(Task.prepare,'/cached.epub','99',metadata,{row},archive),'foreign book accepted')
local wrong=Fixture.clone(row);wrong.markText='Changed quotation'
expect(#Task.prepare('/cached.epub','41',metadata,{wrong},archive).rows==0,'changed quote accepted')
wrong=Fixture.clone(row);wrong.chapterUid=3
expect(#Task.prepare('/cached.epub','41',metadata,{wrong},archive).rows==0,'foreign chapter accepted')
local many={};for n=1,Task.BATCH+1 do many[n]=row end
expect(not pcall(Task.prepare,'/cached.epub','41',metadata,many,archive),'unbounded source batch accepted')
local span=result.rows[1]
local verified=Task.verify{{bookmarkId=row.bookmarkId,text='Unique & selected\ntext',normalized_sha256=span.normalized_sha256},
    {bookmarkId='bad',text='Unique & changed text',normalized_sha256=span.normalized_sha256},
    {bookmarkId='too-large',text=string.rep('a',Task.MAX_NATIVE_BYTES+1),normalized_sha256=span.normalized_sha256}}
expect(#verified==1 and verified[1]==row.bookmarkId,'native full-span verification accepted changed text')
expect(#Task.verify(many)==0,'unbounded native verification accepted')
local point={bookmarkId='synthetic-point',type=0,chapterUid=2,range='15',markText='Unique & selected text'}
local mixed=Task.prepare('/cached.epub','41',metadata,{row,point},archive)
expect(#mixed.rows==2 and mixed.rows[2].bookmark==true and mixed.rows[1].bookmark==nil)
expect(mixed.rows[2].anchor.co==15 and mixed.rows[2].anchor.point_offset==0,'bookmark point shifted')
expect(not mixed.rows[2].first_anchor and not mixed.rows[2].last_anchor and not mixed.rows[2].normalized_sha256,
    'point bookmark was converted into a text range')
for _i,field in ipairs({'range','markText','chapterUid'}) do
    local bad=Fixture.clone(point);bad[field]=({range='15-48',markText='changed',chapterUid=3})[field]
    expect(#Task.prepare('/cached.epub','41',metadata,{bad},archive).rows==0,'invalid bookmark received a DOM anchor')
end
local missing=Fixture.clone(point);missing.markText=nil
expect(#Task.prepare('/cached.epub','41',metadata,{missing},archive).rows==1,'preview-less exact point unavailable')
print('personal_mark_task_spec: '..checks..' checks passed')

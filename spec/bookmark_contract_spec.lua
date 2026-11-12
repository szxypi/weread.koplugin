package.path='./?.lua;'..package.path
local F=require('spec.helpers.mark_edit_fixture');local C=require('weread.lib.mark_edit_contract')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local codec=F.codec();local snapshot=F.snapshot(codec)
local ref={bookmark=true,type=0,bookmarkId='bookmark:2:210:'..string.rep('a',64),range='210',chapterUid=2,chapterIdx=3,
    markText='Synthetic bookmark\r\nnext paragraph',source={book_id='900001',chapter_uid='2',chapter_idx=3,raw_sha256=string.rep('a',64),raw_bytes=1000}}
-- Position bookmarks may coexist with text highlights and linked thoughts;
-- the exact original sets remain protected rather than merged or overwritten.
snapshot.marks.updated[1].chapterUid=2;snapshot.marks.updated[1].range='200-240'
snapshot.thoughts.reviews[1].chapterUid=2;snapshot.thoughts.reviews[1].range='200-240'
local plan=C.make(codec,snapshot,'bookmark_create',ref,{bookId='900001',version=77})
expect(C.validate_body('bookmark_create',plan.body) and C.validate_metadata(plan.metadata),'bookmark plan rejected')
expect(plan.body.type==0 and plan.body.style==0 and plan.body.range=='210' and not plan.body.colorStyle and not plan.body.chapterIdx,'bookmark payload changed')
expect(plan.body.markText==ref.markText and not C.check(snapshot,plan.metadata),'CRLF lost or absent record confirmed')
local added=F.clone(snapshot)
local target={bookmarkId='synthetic-new-bookmark',type=0,chapterUid=2,range='210',style=0,markText=ref.markText,createTime=1001}
added.marks.updated[#added.marks.updated+1]=target
local yes,key=C.check(added,plan.metadata);expect(yes and key==target.bookmarkId,'exact bookmark not confirmed')
for _i,fields in ipairs({{}, {style=0,colorStyle=0,markText=''}}) do
    local missing=F.clone(added);missing.marks.updated[2]={bookmarkId=target.bookmarkId,type=0,chapterUid=2,range='210'}
    for k,v in pairs(fields) do missing.marks.updated[2][k]=v end
    expect(C.check(missing,plan.metadata),'optional server preview/style required')
end
for _i,change in ipairs({{markText='Wrong preview'},{range='211'},{type=1},{chapterUid=3},{style=1},{colorStyle=1}}) do
    local bad=F.clone(added);for k,v in pairs(change) do bad.marks.updated[2][k]=v end
    expect(not C.check(bad,plan.metadata),'changed new bookmark accepted')
end
for _i,group in ipairs({'mark','thought','chapter'}) do
    local bad=F.clone(added)
    if group=='mark' then bad.marks.updated[1].markText='Changed original'
    elseif group=='thought' then bad.thoughts.reviews[1].content='Changed original'
    else bad.marks.chapters[1]={chapterUid=999,title='Other new descriptor'} end
    expect(not C.check(bad,plan.metadata),'unrelated collection changed: '..group)
end
expect(not pcall(C.make,codec,added,'bookmark_create',ref,{bookId='900001',version=77}),'duplicate point created')
local deletion=C.make(codec,added,'bookmark_delete',target)
expect(C.validate_body('bookmark_delete',deletion.body) and C.validate_metadata(deletion.metadata),'bookmark deletion invalid')
expect(C.check(snapshot,deletion.metadata) and not C.check(added,deletion.metadata),'exact deletion not independently confirmed')
expect(not pcall(C.make,codec,added,'delete',target),'point deleted as highlight')
expect(not pcall(C.make,codec,added,'bookmark_delete',added.marks.updated[1]),'highlight deleted as point')
expect(not pcall(C.make,codec,added,'bookmark_delete',F.clone(ref)),'draft used as existing record')
local textref=F.reference();textref.range='300-340';textref.bookmarkId='selection:2:300-340:'..string.rep('a',64)
expect(pcall(C.make,codec,added,'create',textref,{bookId='900001',version=77}),'point blocked an unrelated text selection')
for _i,field in ipairs({'colorStyle','chapterIdx','unknown'}) do
    local body=F.clone(plan.body);body[field]=0
    expect(not C.validate_body('bookmark_create',body),'extra point field accepted')
end
for _i,value in ipairs({'01','1-2','-1','2147483648'}) do
    local body=F.clone(plan.body);body.range=value;expect(not C.validate_body('bookmark_create',body),'invalid point body accepted')
end
local Auth=require('weread.lib.native_authorization');local calls,claimed=0,false
codec.request=function(_self,options)
    calls=calls+1;expect(claimed and options.method=='POST','dispatch before durable claim')
    expect(options.url=='https://i.weread.qq.com/book/'..(calls==1 and 'addBookmark' or 'removeBookmark'),'wrong point route')
    expect(options.sensitive and options.skip_cookie and not options.persist_response_cookies and not options.headers.Cookie,'native credentials escaped')
    return codec:json_encode({succ=1}),200
end
local auth=Auth:new(codec,{expected_vid='900000',is_current=function() return true end})
local credentials={vid='900000',accessToken='synthetic-access'}
expect(not pcall(auth.write_my_highlight,auth,credentials,'bookmark_create',plan.body) and calls==0,'missing claim dispatched')
auth:write_my_highlight(credentials,'bookmark_create',plan.body,function() claimed=true end)
auth:write_my_highlight(credentials,'bookmark_delete',deletion.body,function() claimed=true end)
expect(calls==2,'unexpected mutation count')
print('bookmark_contract_spec: '..checks..' checks')

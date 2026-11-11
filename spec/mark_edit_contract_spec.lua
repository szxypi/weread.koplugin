package.path='./?.lua;'..package.path
local F=require('spec.helpers.mark_edit_fixture');local C=require('weread.lib.mark_edit_contract')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local codec=F.codec();local snapshot=F.snapshot(codec);local ref=F.reference()
local plan=C.make(codec,snapshot,'create',ref,{bookId='900001',version=77})
expect(C.validate_body('create',plan.body) and C.validate_metadata(plan.metadata),'valid creation rejected')
expect(plan.body.chapterIdx==nil and type(plan.body.chapterUid)=='number','guessed native index or wrong UID type')
expect(not C.check(snapshot,plan.metadata),'baseline confirmed creation')
local created=F.created(codec,snapshot);local yes,key=C.check(created,plan.metadata)
expect(yes and key=='synthetic-new-highlight','exact creation not confirmed')
for _i,name in ipairs({'markText','range','chapterUid','type','style','colorStyle'}) do
    local changed=F.clone(created);changed.marks.updated[2][name]=name=='chapterUid' and 9 or 'changed'
    expect(not C.check(changed,plan.metadata),'changed new row confirmed: '..name)
end
for _i,name in ipairs({'markText','range','chapterUid','createTime'}) do
    local changed=F.clone(created);changed.marks.updated[1][name]=name=='chapterUid' and 9 or 'changed'
    expect(not C.check(changed,plan.metadata),'original mark change hidden: '..name)
end
local altered=F.clone(created);altered.thoughts.reviews[1].content='External edit'
expect(not C.check(altered,plan.metadata),'thought mutation hidden')
altered=F.clone(created);altered.marks.chapters[1]={chapterUid=2,title='Selected chapter'}
expect(C.check(altered,plan.metadata),'new selected chapter descriptor rejected')
altered.marks.chapters[2]={chapterUid=999,title='Unrelated chapter'}
expect(not C.check(altered,plan.metadata),'unrelated new descriptor accepted')
altered=F.clone(created);altered.marks.updated[3]=F.clone(altered.marks.updated[2]);altered.marks.updated[3].bookmarkId='second-new'
expect(not C.check(altered,plan.metadata),'duplicate creation accepted')
local deletion=C.make(codec,created,'delete',created.marks.updated[2])
local styling=C.make(codec,created,'style',created.marks.updated[2],nil,2)
expect(C.validate_body('style',styling.body) and C.validate_metadata(styling.metadata),'valid style plan rejected')
local styled=F.clone(created);styled.marks.updated[2].style=2
expect(C.check(styled,styling.metadata) and not C.check(created,styling.metadata),'style-only readback failed')
for _i,name in ipairs({'colorStyle','markText','range','createTime','bookmarkId'}) do
    local changed=F.clone(styled);changed.marks.updated[2][name]=name=='colorStyle' and 3 or 'changed'
    expect(not C.check(changed,styling.metadata),'style confirmation hid another changed field: '..name)
end
local style_linked=F.clone(created);style_linked.thoughts.reviews[1].chapterUid=2;style_linked.thoughts.reviews[1].range=ref.range
expect(pcall(C.make,codec,style_linked,'style',style_linked.marks.updated[2],nil,0),'style change blocked by linked thought')
for _i,invalid in ipairs({-1,3,'2',true}) do expect(not pcall(C.make,codec,created,'style',created.marks.updated[2],nil,invalid),'invalid style accepted') end
expect(not pcall(C.make,codec,created,'style',created.marks.updated[2],nil,1),'unchanged style dispatched')
expect(not C.validate_body('style',{bookmarkId='new',style=2,colorStyle=0,range='1-2'}),'style write added source fields')
expect(C.validate_body('delete',deletion.body) and C.check(snapshot,deletion.metadata),'exact deletion failed')
expect(not C.check(created,deletion.metadata),'remaining mark confirmed deletion')
local with_chapter=F.clone(created);with_chapter.marks.chapters[1]={chapterUid=2,title='Selected chapter'}
local last=C.make(codec,with_chapter,'delete',with_chapter.marks.updated[2])
expect(C.check(snapshot,last.metadata),'last-mark descriptor removal not confirmed')
local remaining=F.clone(with_chapter);remaining.marks.updated[1].chapterUid=2
local remaining_plan=C.make(codec,remaining,'delete',remaining.marks.updated[2])
local after_remaining=F.clone(remaining);table.remove(after_remaining.marks.updated,2);after_remaining.marks.chapters=codec:json_decode('[]')
expect(not C.check(after_remaining,remaining_plan.metadata),'descriptor removal hid a remaining chapter mark')
local changed_title=F.clone(snapshot);changed_title.marks.chapters[1]={chapterUid=2,title='Changed selected title'}
expect(not C.check(changed_title,last.metadata),'changed selected title accepted as removal')
altered=F.clone(created);altered.thoughts.reviews[1].chapterUid=2;altered.thoughts.reviews[1].range=ref.range
expect(not pcall(C.make,codec,altered,'delete',altered.marks.updated[2]),'linked thought deletion allowed')
expect(not pcall(C.make,codec,created,'create',ref,{bookId='900001',version=77}),'overlapping selection allowed')
for _i,operation in ipairs({'create','delete','edit'}) do
    local body=F.clone(operation=='create' and plan.body or deletion.body);body.unexpected=true
    expect(not C.validate_body(operation,body),'extra write field allowed')
end
local Auth=require('weread.lib.native_authorization');local calls,claimed=0,false
codec.request=function(_self,options)
    calls=calls+1;expect(claimed and options.method=='POST' and options.url=='https://i.weread.qq.com/book/removeBookmark','path or claim escaped')
    expect(options.sensitive and options.skip_cookie and options.persist_response_cookies==false and not options.headers.Cookie,'private transport changed')
    return codec:json_encode({succ=1}),200
end
local auth=Auth:new(codec,{expected_vid='900000',is_current=function() return true end})
local credentials={vid='900000',accessToken='synthetic-access'}
expect(not pcall(auth.write_my_highlight,auth,credentials,'delete',deletion.body) and calls==0,'missing claim sent')
auth:write_my_highlight(credentials,'delete',deletion.body,function() claimed=true end)
expect(calls==1,'write replayed')
codec.request=function(_self,options)
    calls=calls+1;expect(claimed and options.url=='https://i.weread.qq.com/book/updateBookmark','style wrote to removal path')
    return codec:json_encode({succ=1}),200
end
auth:write_my_highlight(credentials,'style',styling.body,function() claimed=true end)
expect(calls==2,'style write replayed')
print('mark_edit_contract_spec: '..checks..' checks')

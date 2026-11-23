package.path='./?.lua;'..package.path
local F=require('spec.helpers.thought_edit_fixture')
local C=require('weread.lib.thought_edit_contract')
local Auth=require('weread.lib.native_authorization')
local codec=F.codec();local snapshot=F.snapshot(codec)
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local input='新的实际想法 😀\n第二行'
local imported=F.clone(snapshot);imported.book_id='CB_Synthetic'
local cb_marks=F.marks(codec);cb_marks.bookId=imported.book_id
local cb_plan=C.make(codec,imported,'create',F.mark(),input,cb_marks,{bookId=imported.book_id,version=77},'900000')
expect(C.validate_body('create',cb_plan.body) and C.validate_metadata(cb_plan.metadata) and cb_plan.body.chapterIdx==nil,
    'imported highlight private thought rejected or unverified chapter index included')
local indexed=F.clone(cb_plan.body);indexed.chapterIdx=1
expect(not C.validate_body('create',indexed),'unverified imported chapter index accepted')
local selection=F.clone(F.mark());selection.selection=true
expect(not pcall(C.make,codec,imported,'create',selection,input,cb_marks,{bookId=imported.book_id,version=77},'900000'),
    'unverified imported selection accepted')
local imported_selection=require('spec.helpers.mark_edit_fixture').reference();imported_selection.source.book_id=imported.book_id
local zero_plan=C.make(codec,imported,'create',imported_selection,input,nil,{bookId=imported.book_id,version=0},'900000')
expect(zero_plan.body.bookVersion==0 and C.validate_body('create',zero_plan.body),'zero-version imported thought rejected')
local numeric_selection=require('spec.helpers.mark_edit_fixture').reference()
expect(not pcall(C.make,codec,snapshot,'create',numeric_selection,input,nil,{bookId='900001',version=0},'900000'),
    'zero-version numeric thought accepted')
for _i,operation in ipairs({'edit','delete'}) do
    local safe=C.make(codec,imported,operation,imported.reviews[1],input)
    expect(C.validate_body(operation,safe.body) and C.validate_metadata(safe.metadata),'private imported thought rejected')
    local public=F.clone(imported);public.reviews[1].isPrivate=0
    expect(not pcall(C.make,codec,public,operation,public.reviews[1],input),'public imported thought accepted')
end
expect(C.row_hash(F.row())=='fc64ea1140bd2e72d1fcb42602ef7513f5b1ee7369e8c6ecdd27887de39e61b1','Python row digest differs')
expect(C.snapshot_hash(snapshot)=='7815d1e39244fdb89750b37734ebebb5007cdc0595ba8d8633b5530621f126ff','Python set digest differs')
local image_snapshot=F.snapshot(codec);local image_row=image_snapshot.reviews[1]
image_row.attachment_state='available';image_row.attachment_urls='https://weread-picture-1258476243.file.myqcloud.com/synthetic.png'
expect(C.row_hash(image_row)~=C.row_hash(F.row()),'attachment omitted from record identity')
expect(not pcall(C.make,codec,image_snapshot,'edit',image_row,'updated'),'editing an attachment-bearing thought was allowed')
expect(not pcall(C.make,codec,image_snapshot,'delete',image_row),'unverified old attachment was deletable')
local other=F.snapshot(codec);other.reviews[2]=F.clone(image_row);other.reviews[2].reviewId='other-attachment'
expect(not pcall(C.make,codec,other,'delete',other.reviews[1]),'another unverifiable attachment was ignored')
image_row.attachment_digest=string.rep('a',64)
expect(C.validate_body('delete',C.make(codec,image_snapshot,'delete',image_row).body),'explicit deletion of attachment-bearing thought refused')
local prior=F.clone(image_row);image_row.attachment_digest=string.rep('b',64)
expect(not pcall(C.make,codec,image_snapshot,'delete',prior),'changed attachment metadata was ignored before deletion')
expect(C.digest({'中😀',12,'12'})=='be80ffb5ab35c48e543bcff520d2402918946844ebfdd1c1e7a4bdd2a802d958','Python typed digest differs')
local plan=C.make(codec,snapshot,'create',F.mark(),input,F.marks(codec),{bookId='900001',version=77},'900000')
expect(plan.body.content==input and plan.body.isPrivate==1 and plan.body.chapterUid=='7','user text or private context changed')
expect(C.validate_metadata(plan.metadata) and C.validate_body('create',plan.body),'valid plan rejected')
local observed=F.clone(snapshot);local new=F.row();new.reviewId='synthetic-new';new.content=input;observed.reviews[2]=new
local confirmed,identity=C.check(observed,plan.metadata);expect(confirmed and identity=='synthetic-new','independent create readback failed')
expect(not C.check(snapshot,plan.metadata),'baseline mistaken for create')
for _i,key in ipairs({'isPrivate','abstract','range','chapterUid','content'}) do
    local altered=F.clone(observed);altered.reviews[2][key]=key=='isPrivate' and 0 or key=='chapterUid' and 9 or 'changed'
    expect(not C.check(altered,plan.metadata),'changed context accepted: '..key)
end
local duplicated=F.clone(observed);duplicated.reviews[3]=F.clone(new);duplicated.reviews[3].reviewId='synthetic-duplicate'
expect(not C.check(duplicated,plan.metadata),'duplicate new records accepted')
observed.reviews[1].content='Another device changed the baseline'
expect(not C.check(observed,plan.metadata),'unrelated concurrent edit hidden')
for _i,privacy in ipairs({0,1}) do
    snapshot=F.snapshot(codec);snapshot.reviews[1].isPrivate=privacy
    for _j,op in ipairs({'edit','delete'}) do
        plan=C.make(codec,snapshot,op,snapshot.reviews[1],input)
        expect(C.validate_metadata(plan.metadata) and C.validate_body(op,plan.body),'edit/delete invalid')
        observed=F.clone(snapshot)
        if op=='edit' then observed.reviews[1].content=input else observed.reviews=codec:json_decode('[]') end
        expect(C.check(observed,plan.metadata),'exact edit/delete refused')
        if op=='edit' then observed.reviews[1].isPrivate=1-privacy;expect(not C.check(observed,plan.metadata),'edit changed privacy') end
    end
end
for _i,text in ipairs({'','  \n\t','\0','bad\255',string.rep('x',C.MAX_CONTENT+1)}) do expect(not C.valid_content(text),'bad text accepted') end
expect(C.valid_content(' x\n😀\t中 '),'valid multiline rejected')
snapshot=F.snapshot(codec);local old=F.clone(snapshot.reviews[1]);old.content='stale'
expect(not pcall(C.make,codec,snapshot,'edit',old,input),'stale reference edited')
plan=C.make(codec,snapshot,'delete',snapshot.reviews[1]);plan.body.bookId='900002'
expect(not C.validate_body('delete',plan.body),'extra write field allowed')
-- Fixed-path, private transport and mandatory durable dispatch hook.
local settings,credentials=F.access();local selected=require('weread.lib.native_read_access').capture(settings,credentials)
local calls,claimed=0,false
codec.request=function(_self,options)
    calls=calls+1
    expect(claimed and options.method=='POST' and options.url=='https://i.weread.qq.com/review/delete','dispatch or path escaped')
    expect(options.sensitive and options.skip_cookie and options.persist_response_cookies==false and not options.headers.Cookie,'credential transport leaked')
    return codec:json_encode({succ=1}),200
end
local auth=Auth:new(codec,{expected_vid='900000',is_current=function() return true end})
expect(not pcall(auth.write_my_thought,auth,selected.credentials,'delete',{reviewId='synthetic-note'}) and calls==0,'missing claim permitted')
expect(not pcall(auth.write_my_thought,auth,selected.credentials,'delete',plan.body,function() claimed=true end) and calls==0,'extra scope reached transport')
auth:write_my_thought(selected.credentials,'delete',{reviewId='synthetic-note'},function() claimed=true end)
expect(calls==1,'write retried')
print('PASS: thought edit contract, concurrency predicates and transport ('..checks..' checks)')

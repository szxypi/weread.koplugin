package.path='./?.lua;'..package.path
local F=require('spec.helpers.mark_edit_fixture');local C=require('weread.lib.mark_edit_contract')
local Task=require('weread.lib.mark_edit_task')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function fixture(operation,mode)
    local f={posts=0,claims=0,reads=0,phase='prepared'}
    local client=F.codec();local settings,store,state=F.access();client.settings=settings
    local access=require('weread.lib.native_read_access').capture(settings,store)
    local before=F.snapshot(client);local after=F.created(client,before)
    local bookmark=operation=='bookmark_create' or operation=='bookmark_delete'
    local bookmark_ref
    if bookmark then
        bookmark_ref={bookmark=true,type=0,bookmarkId='bookmark:2:210:'..string.rep('a',64),range='210',chapterUid=2,chapterIdx=3,
            markText='Synthetic bookmark\r\npreview',source={book_id='900001',chapter_uid='2',chapter_idx=3,raw_sha256=string.rep('a',64),raw_bytes=1000}}
        after.marks.updated[2]={bookmarkId='synthetic-new-bookmark',type=0,style=0,chapterUid=2,range='210',markText=bookmark_ref.markText}
    end
    if operation=='delete' or operation=='bookmark_delete' then before,after=after,before end
    if operation=='style' then before=after;after=F.clone(before);after.marks.updated[2].style=2 end
    local reference=operation=='create' and F.reference() or operation=='bookmark_create' and bookmark_ref or before.marks.updated[2]
    local input={book_id='900001',operation=operation,reference=reference,style=operation=='style' and 2 or nil}
    local plan=C.make(client,before,operation,reference,{bookId='900001',version=77},input.style);local record={metadata=plan.metadata}
    local journal={owns=function() return f.phase~='idle' end,claim=function()
        f.claims=f.claims+1;if mode=='claim-failed' or f.phase~='prepared' then return nil end
        f.phase='pending';return true
    end}
    Task.preview=function()
        if mode=='preflight-failed' then error('source unavailable',0) end
        return plan
    end
    Task.observe=function()
        f.reads=f.reads+1
        if mode=='get-failed' then error('get unavailable',0) end
        local value=F.clone(mode=='no-change' and before or after)
        if mode=='other-thought' then value.thoughts.reviews[1].content='External edit' end
        return value
    end
    client.request=function(_self,options)
        expect(f.phase=='pending' and f.claims==1,'dispatch preceded FULL claim')
        f.posts=f.posts+1;expect(f.posts==1,'write repeated')
        if mode=='grant-changed' then state.revision=2 end
        if mode=='lost-ack' then error('synthetic timeout',0) end
        return mode=='bad-json' and 'not-json' or client:json_encode({succ=1}),200
    end
    function f.run(options) options=options or {};options.sleep=function() end;return Task.run(client,settings,access,input,record,journal,options) end
    return f
end
for _i,operation in ipairs({'create','delete','style','bookmark_create','bookmark_delete'}) do
    for _j,mode in ipairs({'normal','lost-ack','bad-json'}) do
        local f=fixture(operation,mode);local result=f.run()
        expect(result.kind=='confirmed' and f.posts==1 and f.phase=='pending','independent readback failed: '..operation..'/'..mode)
        f.run();expect(f.posts==1,'task replay reached write')
    end
    for _j,mode in ipairs({'no-change','other-thought','grant-changed','get-failed'}) do
        local f=fixture(operation,mode);local result=f.run()
        expect(result.kind=='unconfirmed' and result.attempted and f.posts==1 and f.phase=='pending','unknown result lost: '..mode)
    end
    for _j,mode in ipairs({'preflight-failed','claim-failed'}) do
        local f=fixture(operation,mode);local result=f.run()
        expect(not result.attempted and f.posts==0 and f.phase=='prepared','preflight failure wrote: '..mode)
    end
end
print('mark_edit_task_spec: '..checks..' checks')

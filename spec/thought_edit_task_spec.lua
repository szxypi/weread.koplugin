package.path='./?.lua;'..package.path
local F=require('spec.helpers.thought_edit_fixture')
local C=require('weread.lib.thought_edit_contract')
local Task=require('weread.lib.thought_edit_task')
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture(op,mode)
    local f={posts=0,reads=0,claims=0,phase='prepared',mode=mode,op=op}
    local settings,credentials,auth=F.access();local selected=require('weread.lib.native_read_access').capture(settings,credentials)
    local client=F.codec();client.settings=settings
    f.snapshot=F.snapshot(client);f.input={book_id='900001',operation=op,reference=op=='create' and F.mark() or F.row(),content='新的实际想法 😀'}
    local plan=C.make(client,f.snapshot,op,f.input.reference,f.input.content,op=='create' and F.marks(client),{bookId='900001',version=77},'900000')
    f.record={metadata=plan.metadata}
    local journal={owns=function() return f.phase~='idle' end,claim=function()
        f.claims=f.claims+1
        if f.mode=='claim_failed' or f.phase~='prepared' then return nil end
        f.phase='pending';return true
    end}
    Task.observe=function()
        f.reads=f.reads+1
        if f.mode=='get_failed' then error('unavailable',0) end
        if f.mode=='expired' then error('my_thoughts/native_expired',0) end
        local snapshot=F.clone(f.snapshot)
        if f.mode=='preflight_changed' and f.posts==0 then snapshot.reviews[1].content='External change' end
        return snapshot
    end
    client.request=function(_self,options)
        if options.method=='GET' then
            return client:json_encode(options.url:find('/book/info',1,true) and {bookId='900001',version=77} or F.marks(client)),200
        end
        expect(f.phase=='pending' and f.claims==1,'POST preceded durable claim')
        f.posts=f.posts+1;expect(f.posts==1,'one task sent more than once')
        local body=client:json_decode(options.body)
        if mode~='no_change' and mode~='rejected' then
            if op=='create' then local row=F.row();row.reviewId='synthetic-new';row.content=body.content;f.snapshot.reviews[2]=row
            elseif op=='edit' then f.snapshot.reviews[1].content=body.content else f.snapshot.reviews=client:json_decode('[]') end
        end
        if mode=='privacy_changed' and op=='create' then f.snapshot.reviews[2].isPrivate=0 end
        if mode=='other_changed' and op~='delete' then f.snapshot.reviews[1].createTime=1001 end
        if mode=='grant_changed' then auth.revision=2 end
        if mode=='lost_ack' then error('synthetic timeout',0) end
        if mode=='bad_json' then return 'not-json',200 end
        return client:json_encode({succ=mode=='rejected' and 0 or 1}),mode=='rejected' and 401 or 200
    end
    function f.run(options)
        options=options or {};options.sleep=function() end
        return Task.run(client,settings,selected,f.input,f.record,journal,options)
    end
    return f
end
for _i,op in ipairs({'create','edit','delete'}) do
    for _j,mode in ipairs({'normal','lost_ack','bad_json'}) do
        local f=fixture(op,mode);local result=f.run()
        expect(result.kind=='confirmed' and result.attempted and f.posts==1 and f.phase=='pending','valid readback not confirmed: '..op..'/'..mode)
        f.run();expect(f.posts==1 and f.claims==1,'replayed task reached POST')
    end
end
for _i,mode in ipairs({'no_change','rejected','privacy_changed','other_changed','grant_changed'}) do
    local f=fixture('create',mode);local result=f.run()
    expect(result.kind=='unconfirmed' and result.attempted and f.posts==1 and f.phase=='pending','uncertainty lost: '..mode)
end
for _i,mode in ipairs({'preflight_changed','expired','get_failed','claim_failed'}) do
    local f=fixture('edit',mode);local result=f.run()
    expect(not result.attempted and f.posts==0 and f.phase=='prepared','preflight failure dispatched: '..mode)
end
local f=fixture('edit','normal');f.input.content=F.row().content
f.record.metadata=C.make(F.codec(),F.snapshot(F.codec()),'edit',F.row(),f.input.content).metadata
local result=f.run();expect(result.kind=='noop' and not result.attempted and f.posts==0,'unchanged text dispatched')
for _i,clock_after in ipairs({99,221}) do
    f=fixture('create','normal');local clock=100;local preview=Task.preview
    Task.preview=function(...) local plan=preview(...);clock=clock_after;return plan end
    result=f.run{now=function() return clock end,started=100,deadline=220};Task.preview=preview
    expect(not result.attempted and f.posts==0 and f.claims==0 and f.phase=='prepared','delayed source check dispatched outside its time window')
end
print('PASS: thought single dispatch, lost receipts and exact readback ('..checks..' checks)')

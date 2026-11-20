package.path='./?.lua;./?/init.lua;'..package.path
local Access=require('weread.lib.read_access')
local Data=require('weread.lib.shelf_progress')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local cb='CB_SyntheticAlpha'
for _i,id in ipairs({'900001',cb,'CB_1','CB_'..string.rep('a',64)}) do
    expect(Access.display_book_id(id)==id,'valid display identity rejected')
end
for _i,id in ipairs({cb,'CB_1'}) do expect(not Access.book_id(id),'numeric account/chapter validator widened') end
for _i,id in ipairs({'CB_','CB_'..string.rep('a',65),'cb_abc','CB_a_b','CB_a-b','CB_a/b','CB_a?b=1','CB_中文','MP_WXS_test',false,0}) do
    expect(not Access.display_book_id(id),'invalid display identity accepted')
end
local cookies={wr_vid='900000',wr_skey='synthetic-web-access'}
local scope={vid='900000',epoch=1}
local gateway=true
local settings={cache_dir='synthetic-cache',data_dir='synthetic-data',
    get=function(_self,key,default)
        if key=='api_key' then return gateway and 'synthetic-key' or '' end
        if key=='cookies' then return cookies end
        return default
    end,
    get_auth_scope=function() return scope end,
    auth_scope_matches=function(_self,value) return value==scope end,
}
local calls,behavior={},nil
local client={settings=settings,get_shelf_display_progress=function(_self,id,access)
    calls[#calls+1]={id=id,kind=access.kind}
    if behavior then behavior(id,access) end
    return {book={bookId=id,progress=37.8}}
end}
local context={checkCancelled=function() end,emit=function() end}
local selected=Data.selection(settings)
expect(Data.supports(cb,selected) and Data.supports('900001',selected),'Web CB display was not available')
for _i,value in ipairs({{},false,{gateway={kind='gateway'}},{web=false}}) do
    expect(not Data.supports(cb,value),'CB support appeared without Web authorization')
end
local batch=Data.fetch(client,{'900001',cb,'900002'},context,selected)
expect(not batch.failed and #batch.snapshots==3 and #calls==3,'mixed display batch failed')
expect(calls[1].kind=='gateway' and calls[2].kind=='web' and calls[3].kind=='gateway','CB changed the ordinary-book selected channel')
expect(batch.snapshots[1].source=='gateway' and batch.snapshots[2].source=='web' and batch.snapshots[3].source=='gateway',
    'CB snapshot lost its actual source')
calls={}
behavior=function(id,access) if id=='900002' and access.kind=='gateway' then error('private failure',0) end end
batch=Data.fetch(client,{cb,'900002','900003'},context,selected)
expect(not batch.failed and #calls==4 and calls[1].kind=='web' and calls[2].kind=='gateway'
    and calls[3].kind=='web' and calls[4].kind=='web','ordinary gateway fallback or CB-only routing changed')
calls={}
behavior=function(id) if id==cb then error('display_progress/login',0) end end
batch=Data.fetch(client,{'900001',cb,'900002'},context,selected)
expect(batch.failed and batch.web_expired and batch.next_index==2 and #batch.snapshots==1 and #calls==2,
    'CB 401 discarded the prefix or read beyond the failed suffix')
calls={};behavior=nil
cookies={}
selected=Data.selection(settings)
batch=Data.fetch(client,{cb,'900001'},context,selected)
expect(batch.failed and #calls==0,'CB reached a gateway-only batch')
local jobs={}
local host=setmetatable({settings=settings,client=client,shelf_view={},
    library_db={accountKey=function() return 'synthetic-account' end},
    isNetworkOnline=function() return true end,
    shelf_progress_worker={available=function() return true end,start=function(_self,options)
        jobs[#jobs+1]=options;return true,{options=options}
    end,cancel=function() end},
},{__index=require('weread.ui.shelf_progress')})
host:refreshVisibleShelfProgress(host.shelf_view,{{bookId=cb},{bookId='900001'}},{},{})
expect(#jobs==1,'gateway-only visible batch lost its ordinary book')
batch=jobs[1].task(context)
expect(not batch.failed and #calls==1 and calls[1].id=='900001' and #batch.snapshots==1,
    'gateway-only UI scheduled a CB read or blocked an ordinary book')
cookies={wr_vid='900000',wr_skey='synthetic-web-access'}
selected=Data.selection(settings);calls={}
behavior=function() cookies.wr_skey='synthetic-replaced-web' end
batch=Data.fetch(client,{cb,'900001'},context,selected)
expect(batch.stale and #batch.snapshots==0 and #calls==1,'authorization change retained CB progress')
local saved={recent_read_account='account-a',pending_upload_position={book_id=cb,percent=83}}
local value,pending=Data.display(saved,{percent=37},'account-a',cb)
expect(value==83 and pending,'CB cloud display replaced pending local reading')
expect(Data.display(saved,{percent=37},'account-b',cb)==37,'CB local reading escaped account ownership')
print(('cb_shelf_progress_spec: %d checks'):format(checks))

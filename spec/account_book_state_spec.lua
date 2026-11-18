package.path='./?.lua;./?/init.lua;'..package.path
local Scope=require('weread.lib.account_book_state')
local n=0
local function expect(v,m) n=n+1;assert(v,m) end
local fields={pending_upload_position=true,pending_upload_reason=true,pending_upload_account=true,
    last_local_position=true,last_local_account=true,home_recent_at=true,home_recent_account=true,
    unindexed_resume=true,cb_cloud_view_resume=true,source_dispatch=true,progress=true}
local a,b=string.rep('a',20),string.rep('b',20)
local metadata={recent_read_account=a,_library_account_key=a}
local state={pending_upload_position={percent=31},pending_upload_reason='pending',last_local_position={percent=32},
    home_recent_at=10,home_recent_account=a,source_dispatch={account=a,id='uncertain'},progress=33}
local mine=Scope.legacy(metadata,state,fields,a)
expect(mine.pending_upload_position.percent==31 and mine.last_local_position.percent==32 and mine.progress==33,
    'legacy owner lost its own positions')
expect(mine.source_dispatch.id=='uncertain' and mine.home_recent_at==10,'legacy owner lost dispatch or event')
expect(not next(Scope.legacy(metadata,state,fields,b)),'foreign account inherited legacy reading state')
state.last_local_account=b;state.home_recent_account=b;state.pending_upload_account=b
local theirs=Scope.legacy(metadata,state,fields,b)
expect(theirs.pending_upload_position.percent==31 and theirs.last_local_position.percent==32 and theirs.home_recent_at==10,
    'explicit position owner lost to older metadata')
expect(not theirs.progress and not theirs.source_dispatch,'foreign shared state escaped its owner')
state.pending_upload_account='';state.last_local_account='';state.home_recent_account=''
local unowned=Scope.legacy({},state,fields,a)
expect(not unowned.pending_upload_position and not unowned.last_local_position and not unowned.home_recent_at,
    'unowned legacy positions were claimed')
state.source_dispatch={id='uncertain'}
expect(Scope.legacy({},state,fields,b).source_dispatch.id=='uncertain','uncertain dispatch failed open')
state.source_dispatch=nil;state.unindexed_resume={owner=b,chapter_uid='1'}
expect(Scope.legacy(metadata,state,fields,b).unindexed_resume.chapter_uid=='1','indexed owner not respected')
expect(not Scope.legacy(metadata,state,fields,a).unindexed_resume,'foreign unindexed hint was inherited')
state.cb_cloud_view_resume={owner=b,chapter_uid='2'}
expect(Scope.legacy(metadata,state,fields,b).cb_cloud_view_resume.chapter_uid=='2','cloud view owner not respected')
expect(not Scope.legacy(metadata,state,fields,a).cb_cloud_view_resume,'foreign cloud view hint was inherited')
print('account_book_state_spec: '..n..' checks')

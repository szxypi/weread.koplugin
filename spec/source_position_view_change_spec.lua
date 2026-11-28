package.path='./?.lua;'..package.path
local Service=require('weread.lib.source_position')
local Identity=require('weread.lib.book_file_identity')
local original=Identity.read_document
Identity.read_document=function() return {book_id='42',file_id=string.rep('a',64)} end
local page,calls=1,0
local document={file='/synthetic.epub'}
local account='account-a'
local context={location=function()
    calls=calls+1
    return {page=page,pos=page*100,xpointer='point-'..page,view_mode='page'}
end}
local queued
local scheduler={scheduleIn=function(_,_,task) queued=task end,
    unschedule=function(_,task) if queued==task then queued=nil end end}
local service=Service:new{scheduler=scheduler,context=context,get_document=function() return document end,
    get_book_id=function() return '42' end,get_account=function() return account end}
local checks=0
local function expect(condition,message) checks=checks+1;assert(condition,message) end
service:on_reader_ready()
local first=service.job
calls=0;page=2;service:on_view_changed()
expect(calls==1,'moved page repeated native location capture')
expect(first~=service.job and service.job.scope.location.page==2,'moved page kept stale work')
first=service.job;calls=0;service:on_view_changed()
expect(calls==2 and first==service.job,'unchanged page skipped its independent recheck')
-- A retained-target callback can change state after the first snapshot. A
-- matching initial snapshot must never authorize an outdated job.
service.get_retained=function() page=3;return nil end
calls=0;first=service.job;service:on_view_changed()
expect(calls==2 and first~=service.job,'movement during retained-target check was accepted')
expect(service.job.scope.location.page==2,'changed behavior of first snapshot on invalidation')
service.get_retained=nil;service:on_view_changed()
expect(service.job.scope.location.page==3,'later page event did not capture new state')
first=service.job;account='account-b';calls=0;service:on_view_changed()
expect(calls==1 and first~=service.job and service.job.scope.account=='account-b',
    'account change kept the previous scope')
service:stop();expect(not service.job and not queued,'stop retained scheduled work')
Identity.read_document=original
print(('source_position_view_change_spec: %d checks'):format(checks))

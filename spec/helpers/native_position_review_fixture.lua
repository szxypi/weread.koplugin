local F=require('spec.helpers.thought_edit_fixture')
local C=require('weread.lib.native_position_contract')
local M={}
function M.new()
    local f={clock=100,current=true,events={},starts=0,stops=0,archives=0}
    f.settings,f.credentials,f.auth=F.access()
    local grant={vid='900000',deviceId='eink334691225'..string.rep('1',19),accessToken='synthetic-access',refreshToken='synthetic-refresh'}
    function f.credentials:read() return grant,f.auth.revision,nil,f.auth.pending end
    f.client=F.codec()
    local point={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17,summary='synthetic cloud full summary'}
    f.observation={point=F.clone(point),counts={readingTime=10,recordReadingTime=20,ttsTime=0},version=0,shelf_sha256=string.rep('a',64)}
    f.row={schema=1,phase='pending',revision=2,id=string.rep('1',32),epoch=1,account=C.account_key('900000'),metadata={book_id='41',
        before=F.clone(point),desired=F.clone(point),counts=F.clone(f.observation.counts),version=0,shelf_sha256=string.rep('a',64),
        source_sha256=string.rep('b',64),file_id='synthetic-file',basis='raw_txt_utf16'}}
    f.journal={read=function() return F.clone(f.row) end,archive=function(_self,record,observation)
        f.archives=f.archives+1
        assert(record.revision==f.row.revision and record.phase==f.row.phase and observation.point.book_id=='41')
        if f.fail_archive then return false end
        f.history=F.clone(record);f.row={schema=1,phase='idle',account=f.row.account,revision=f.row.revision+1};return true
    end}
    f.scheduler={scheduleIn=function(_self,_delay,callback) f.events[callback]=true end,unschedule=function(_self,callback) f.events[callback]=nil end}
    f.worker={start=function(_self,task,callback) f.starts=f.starts+1;f.task,f.deliver=task,callback;return not f.fail_start end,
        cancel=function() f.stops=f.stops+1 end}
    f.guard=function() assert(not f.inside,'native document used in child');return f.current end
    f.gate={valid=function() return not f.gate_closed end,close=function() f.gate_closed=true end}
    f.options={client=f.client,settings=f.settings,credentials=f.credentials,journal=f.journal,scheduler=f.scheduler,worker=f.worker,
        guard_factory=function() return f.gate end,now=function() return f.clock end}
    f.callback=function(result,token) f.result,f.token=result,token end
    return f
end
return M

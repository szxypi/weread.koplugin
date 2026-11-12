package.path='./?.lua;'..package.path
local Close=require('weread.lib.source_close')
local Source=require('weread.lib.position_source')
local Currentness=require('weread.lib.source_currentness')
local Native=require('weread.lib.native_source_upload')
local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(v,why) checks=checks+1;assert(v,why or ('check '..checks)) end
local active
Source.document_metadata=function()
    expect(active.alive,'closed document queried');return {metadata='synthetic',identity={file_id=active.point.file_id},record={raw_bytes=500}}
end
Currentness.capture=function() return active.access end
Currentness.matches=function(_settings,access) return active.valid and access==active.access end
Native.new=function(_self,options)
    local f=active;f.face=options.source
    local controller={cancel=function() f.cancelled=f.cancelled+1 end,
        prepare=function(_controller,intent,cb) f.prepared=F.clone(intent);f.ready=cb;return true end}
    f.controller=controller;return controller
end
local function fixture()
    local f={alive=true,valid=true,clock=100,access={web={}},cancelled=0,timers={},callbacks=0};active=f
    f.point={book_id='41',chapter_uid='2',chapter_offset=13,file_id=string.rep('a',64),raw_sha256=string.rep('b',64),
        book_version=7,render_path='OEBPS/text/chapter.xhtml',basis='raw_txt_utf16',upload_verified=false,chapter_title='Synthetic'}
    f.remote={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17,has_chapter_offset=true,has_chapter_index=true,source='web'}
    f.intent={book_id='41',chapter_uid=2,chapter_idx=3,chapter_offset=1,percent=18,source_position=F.clone(f.point),
        native_position_only=true,expected_remote=F.clone(f.remote)}
    local function native() expect(f.alive,'closed native source consulted') end
    f.settings={data_dir='synthetic-native-close-profile',get_auth_scope=function() return {vid='900000',epoch=1} end,
        auth_scope_matches=function() return f.valid end}
    f.source={client={settings=f.settings},current=function() native();return F.clone(f.point) end,
        is_busy=function() native();return false end,can_prepare=function() native();return true end,
        _live=function() native();return {file='fixture.epub'} end,_current=function() native();return true end,
        get_document=function() native();return {} end,
        get_upload_context=function() native();return {book_id='41',percent=18,chapters={{chapterUid=2,chapterIdx=3}}} end,
        is_online=function() return true end}
    f.scheduler={scheduleIn=function(_self,delay,fn) expect(delay>=.1);f.timers[fn]=true end,
        unschedule=function(_self,fn) f.timers[fn]=nil end}
    function f:new() return Close:new{source=self.source,scheduler=self.scheduler,now=function() return self.clock end,
        get_catalog=function() return {{chapterUid=2,chapterIdx=3}} end} end
    f.service=f:new()
    function f:freeze() return assert(self.service:freeze(F.clone(self.intent))) end
    function f:prepare(token)
        self.alive=false
        return self.service:prepare(token,F.clone(self.intent),function(plan,reason) self.plan,self.reason=plan,reason;self.callbacks=self.callbacks+1 end)
    end
    function f:deliver()
        self.sent=0
        self.ready{transport='native_position',basis='raw_txt_utf16',position={chapter_offset=13},source_position=F.clone(self.point),
            is_current=function() return true end,release=function() error('wrapper bypassed namespace cleanup') end,
            dispatch=function(cb) self.sent=self.sent+1;self.deliver_result=cb;return true end}
    end
    return f
end
local f=fixture();local token=f:freeze();f.intent.expected_remote.chapter_offset=999;expect(f:prepare(token));f:deliver()
expect(f.prepared.expected_remote.chapter_offset==12 and f.prepared.native_position_only,'close cloud decision was not frozen')
expect(f.face.input.target.chapter_title==nil and f.face:current().chapter_offset==13,'raw packet was not pinned to primitives')
expect(f.plan.detached and f.plan.is_current() and f.callbacks==1)
f.plan.detached=false;expect(not f.plan.is_current() and not f.plan.dispatch(function() end) and f.sent==0,'detachment mutation reached native sender')
f.plan.detached=true
expect(f.plan.dispatch(function() f.plan.release();f.saved=true end));f.deliver_result(true,true,{})
expect(f.saved and f.cancelled==1 and not f.plan.is_current() and next(f.timers)==nil,'completion retained closed namespace')
f=fixture();token=f:freeze();local untyped=F.clone(f.intent);untyped.native_position_only=nil
expect(not f.service:freeze(untyped),'untyped source enabled native close')
expect(f:prepare(token),'untyped rejection cancelled an already frozen plan');f.service:cancel()
expect(f.callbacks==1 and not f.plan and f.reason=='source_cancelled')
f=fixture();token=f:freeze();f:prepare(token);f:deliver();f:new():on_reader_ready('41')
expect(not f.plan.is_current() and f.cancelled==1,'new reader instance did not cancel old close namespace')
f=fixture();token=f:freeze();f:prepare(token);f:deliver();local old=f.plan
f.alive=true;local next_token=f:freeze();old.release();expect(f:prepare(next_token),'old release cancelled a newer freeze')
f:deliver();f.plan.release()
f=fixture();token=f:freeze();f:prepare(token);f.clock=136
local timeout=next(f.timers);timeout();expect(f.callbacks==1 and not f.plan and f.reason=='source_preparation_timeout')
f=fixture();token=f:freeze();f:prepare(token);f:deliver();f.plan.dispatch(function() error('synthetic local commit failed') end)
expect(not pcall(f.deliver_result,true,true,{}) and f.cancelled==1 and not f.plan.is_current(),'failed local save hid failure from native receipt owner')
print(('native_source_close_spec: %d checks'):format(checks))

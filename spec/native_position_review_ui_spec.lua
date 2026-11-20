package.path='./?.lua;'..package.path
local stack={};local UI={show=function(_self,w) stack[#stack+1]=w end,close=function(_self,w)
    for i=#stack,1,-1 do if stack[i]==w then table.remove(stack,i);return end end
end}
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,o) return o end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(t) return t end} end
package.preload['ffi/util']=function() return {template=function(s,...) local a={...};return (s:gsub('%%([1-9])',function(n) return tostring(a[tonumber(n)]) end)) end} end
local Review=require('weread.lib.native_position_review');local new=Review.new
local View=require('weread.ui.native_position_review')
local F=require('spec.helpers.thought_edit_fixture');local Fixture=require('spec.helpers.native_position_review_fixture')
local checks=0;local function expect(v,why) checks=checks+1;assert(v,why) end
local function fixture()
    stack={};local f=Fixture.new();f.options.task=function() return {kind='observed',readbacks=2,observation=F.clone(f.observation)} end
    f.review=new(Review,f.options);Review.new=function() return f.review end
    f.marker='synthetic-marker';f.document={};f.compares=0;f.begins=0
    local sync={navigation_generation=1,is_online=function() return f.current end,get_document=function() return f.document end,
        _recovery_marker=function() return f.marker end,_scope=function() return {navigation_generation=1} end,
        _session_current=function() return f.session~=false end,
        begin_native_review=function() f.begins=f.begins+1 end,compare_after_native_review=function() f.compares=f.compares+1 end}
    f.host={settings=f.settings,client=f.client,progress_sync=sync,library_db={open=function() end,getBook=function() return {title='Synthetic book'} end},
        source_upload={cancel=function() f.upload_cancelled=true end},showInfo=function(_self,text) f.info=text end,
        showBusy=function(self,text,cancel) self.busy_message={text=text,cancel=cancel} end,
        closeBusy=function(self) self.busy_message=nil end}
    function f:inspect() expect(View.open(self.host));local dialog=stack[#stack];expect(dialog.ok_text=='Check cloud position');dialog.ok_callback() end
    function f:run() self.deliver(self.task()) end
    return f
end
local f=fixture();f:inspect();expect(f.begins==1 and f.upload_cancelled and f.row.phase=='pending' and f.host.busy_message)
f:run();local confirm=stack[#stack];expect(confirm.ok_text=='Archive and compare again' and confirm.text:find('no confirmed receipt',1,true))
expect(confirm.text:find('17%.',1,true) and not confirm.text:find('17%%',1,true),'percent duplicated')
confirm.ok_callback();expect(f.archives==1 and f.history.phase=='pending' and f.compares==1 and not f.host._native_position_review_ui)
f=fixture();f:inspect();f:run();stack[#stack].cancel_callback();expect(f.row.phase=='pending' and f.archives==0 and f.compares==0)
f=fixture();f:inspect();f.host.busy_message.cancel();f.deliver({kind='observed',readbacks=2,observation=f.observation})
expect(f.row.phase=='pending' and not f.host._native_position_review_ui and not f.host.busy_message)
for _i,change in ipairs({'page','session','navigation','offline','document'}) do
    f=fixture();f:inspect();f:run();local old=stack[#stack]
    if change=='page' then f.marker='moved' elseif change=='session' then f.session=false
    elseif change=='navigation' then f.host.progress_sync.navigation_generation=2
    elseif change=='offline' then f.current=false else f.document={} end
    View.view_changed(f.host);old.ok_callback();expect(f.archives==0 and f.compares==0 and not f.host._native_position_review_ui,'stale '..change..' applied')
end
f=fixture();expect(View.open(f.host));local old=stack[#stack]
View.cancel(f.host);f.review=new(Review,f.options);Review.new=function() return f.review end;expect(View.open(f.host))
local owned=f.host._native_position_review_ui;old.cancel_callback();old.ok_callback()
expect(f.host._native_position_review_ui==owned,'stale dialog cancelled newer review');View.cancel(f.host)
f=fixture();f:inspect();f:run();f.fail_archive=true;stack[#stack].ok_callback()
expect(f.row.phase=='pending' and f.compares==0 and f.info:find('record and local position are kept',1,true))
f=fixture();f.row.phase='idle';expect(not View.open(f.host) and f.begins==0)
f=fixture();f.host.progress_sync.uploading=true;expect(View.open(f.host) and f.begins==0 and f.starts==0)
f=fixture();expect(View.open(f.host));f.row.revision=3;stack[#stack].ok_callback()
expect(f.starts==0 and f.archives==0 and f.info:find('changed during the check',1,true),'new row was reviewed under an old title')
f=fixture();f.observation.point=assert(require('weread.lib.native_cloud_state').from({progress=0,chapterUid=0,chapterOffset=0},'41'))
f:inspect();f:run();local absent=stack[#stack]
expect(absent.text:find('WeRead has no chapter position',1,true) and not absent.text:find('0%',1,true),'absence shown as an actual zero-percent coordinate')
absent.ok_callback();expect(f.history.phase=='pending' and f.compares==1,'absence erased unknown request history')
Review.new=new
print('native_position_review_ui_spec: '..checks..' checks')

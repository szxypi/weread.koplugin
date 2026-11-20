package.path="./?.lua;"..package.path
local Metadata=require("weread.lib.book_metadata")
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local source={bookId="900001",title="Synthetic book",author="Synthetic author",intro="First paragraph\n\nSecond paragraph",
    publisher="Synthetic publisher",isbn="9780000000000",newRating=870,newRatingCount=12,category="Literature",publishTime="2026-01-01",
    wordCount=12345,token="private-session",psvts="private-clock",progress=99,chapterOffset=123,version=8,bookVersion=9}
local projected=Metadata.normalize(source,"900001")
expect(projected.title==source.title and projected.intro==source.intro and projected.categoryName=="Literature","display fields missing")
for _,key in ipairs({"token","psvts","progress","chapterOffset","version","bookVersion"}) do
    expect(projected[key]==nil,"reader/session field escaped projection")
end
for _,invalid in ipairs({{}, {bookId="900002",title="Wrong book"},{bookId="900001",title="bad\nname"},
    {bookId="900001",title=string.rep("x",4097)},{bookId="900001",title=""},{bookId="900001",title="Rejected",errcode=-1}}) do
    expect(not pcall(Metadata.normalize,invalid,"900001"),"invalid metadata accepted")
end
local fields=Metadata.normalize({bookId="900001",title="Book",intro=string.rep("x",65537),author="bad\0author",
    wordCount=0/0,newRating=1001,newRatingCount=-1,publishTime=math.huge},"900001")
expect(fields.intro==nil and fields.author==nil and fields.wordCount==nil and fields.newRating==nil
    and fields.newRatingCount==nil and fields.publishTime==nil,"invalid optional field escaped bounds")
local encoded='{"reader":{"bookInfo":{"title":"nested { braces }"}}}'
local html='<script>window.__INITIAL_STATE__ = '..encoded..';(function(){})();</script>'
expect(Metadata.from_reader(html,"900001",function(bytes) expect(bytes==encoded,"state extraction changed JSON")
    return {reader={bookInfo=source}} end).title==source.title,"reader metadata missing")
expect(not pcall(Metadata.from_reader,'{"bookId":"900001","title":"untrusted regex fallback"}',"900001",function() return {} end),
    "unparsed HTML accepted by loose fallback")
expect(not pcall(Metadata.from_reader,html,"900001",function() error("private malformed body") end),"bad state JSON accepted")

local key,cookies,valid="",{wr_vid="900000",wr_skey="synthetic-web-access"},true
local scope={vid="900000",epoch=1}
local settings={get=function(_self,name,default)
    if name=="api_key" then return key end
    if name=="cookies" then return cookies end
    return default
end,get_auth_scope=function() return scope end,auth_scope_matches=function() return valid end}
local routes={}
local client={settings=settings,get_display_book_metadata=function(_self,_id,access)
    routes[#routes+1]=access.kind
    if access.kind=="gateway" then error("private gateway error") end
    return source
end}
expect(Metadata.fetch(client,"900001").source=="web" and #routes==1,"keyless metadata contacted another source")
key="synthetic-api-key";routes={}
expect(Metadata.fetch(client,"900001").source=="web" and table.concat(routes,",")=="gateway,web","metadata fallback repeated or skipped Web")
client.get_display_book_metadata=function() cookies={} return source end
local ok,err=pcall(Metadata.fetch,client,"900001")
expect(not ok and err=="book_metadata/session_changed","changed access retained metadata")
key="";valid=false
ok,err=pcall(Metadata.fetch,client,"900001")
expect(not ok and err=="book_metadata/access_required","unverified metadata access accepted")

package.preload["ui/uimanager"]=function() return {close=function() end,scheduleIn=function(_self,_delay,cb) cb() end} end
package.preload["weread.lib.plugin_util"]=function() return {tr=function(value) return value end} end
local UI=require("weread.ui.book_metadata")
local function fixture()
    key="";cookies={wr_vid="900000",wr_skey="synthetic-web-access"};valid=true
    local books={['900001']={book_id="900001",title="Old title",progress=83,chapter_uid=99,bookVersion=7,
        pending_upload_position={percent=83},cached_file="existing.epub"}}
    local job,shown,saves,flushed,errors,qr,cancels=nil,nil,0,0,0,0,0
    local owner,online,guest_epoch="account-a",true,0
    local original_get=settings.get
    local local_settings={get=function(_self,name,default)
        if name=="books" then return books end
        if name=='auth_epoch' then return guest_epoch end
        return original_get(settings,name,default)
    end,get_auth_scope=function() if owner then return settings:get_auth_scope() end end,auth_scope_matches=settings.auth_scope_matches,
        set=function(_self,name,value) expect(name=="books","metadata changed another setting") books=value end,
        flush=function() flushed=flushed+1 end}
    local host={settings=local_settings,discovery_epoch=1,
        client={settings=local_settings,get_display_book_metadata=function(_self,id) local copy={} for k,v in pairs(source) do copy[k]=v end copy.bookId=id return copy end,
            get_public_book_metadata=function(_self,id) local copy={} for k,v in pairs(source) do copy[k]=v end copy.bookId=id return {data={copy}} end},
        library_db={accountKey=function() return owner end,putBook=function() saves=saves+1 return true end},
        isNetworkOnline=function() return online end,
        showBusy=function(self,_label,cancel) self.busy_message={};self.cancel_busy=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        showBookMenu=function(_self,book) shown=book end,showTransientInfo=function() end,
        showOffline=function() errors=errors+1 end,showInfo=function() errors=errors+1 end,
        qr_login={start=function() qr=qr+1 end},
        book_metadata_worker={start=function(_self,task,cb) job={task=task,cb=cb};return true end,
            cancel=function() cancels=cancels+1 end}}
    return host,function() return job,books,shown,saves,flushed,errors,qr,cancels end,
        function(value)
            if value.signed_out then owner=nil elseif value.owner~=nil then owner=value.owner end
            if value.online~=nil then online=value.online end
            if value.auth_epoch~=nil then guest_epoch=value.auth_epoch end
        end
end
local host,state=fixture()
local original_view={}
host._book_detail_view=original_view
expect(UI.refresh(host,{book_id="900001",progress=12},original_view,{automatic=true}),"async metadata did not start")
-- A caller-provided view must still be current when it completes.
local job=state()
local active_context=host.book_metadata_context
expect(not UI.refresh(host,{book_id="900001"},{},{automatic=true}) and host.book_metadata_context==active_context,
    "an old detail callback cancelled the current request")
host._book_detail_view=nil
job.cb(job.task())
local _,_,_,saves=state()
expect(saves==0 and not host.book_metadata_context,"stale detail view wrote metadata")
host,state=fixture()
expect(UI.refresh(host,{book_id="900001",progress=12},nil,{automatic=true}) and host.busy_message,"automatic refresh not async")
local books
job,books=state()
books['900001'].progress=84;books['900001'].chapter_uid=100;books['900001'].bookVersion=9
local result=job.task();result.metadata.chapter_uid=1;result.metadata.progress=1;result.metadata.token="private-session"
job.cb(result)
local _,_,shown,save_count,flush_count=state()
expect(save_count==1 and flush_count==1 and shown.title==source.title,"metadata not saved/shown")
expect(shown.progress==84 and shown.chapter_uid==100 and shown.bookVersion==9 and shown.pending_upload_position.percent==83
    and shown.cached_file=="existing.epub" and shown.token==nil,"metadata overwrote current reader/download state")
expect(not host.busy_message and not host.book_metadata_context,"completion retained busy state")
host,state=fixture();UI.refresh(host,{book_id='900001'},nil,{automatic=true});job,books=state()
local wrong={book_id='900002',title='Other',cached_file='other.epub'}
books['900001']=wrong;job.cb(job.task())
local _,conflict_books,conflict_shown,conflict_saves,conflict_flushes,conflict_errors=state()
expect(conflict_books['900001']==wrong and wrong.book_id=='900002' and wrong.title=='Other'
    and not conflict_shown and conflict_saves==0 and conflict_flushes==0 and conflict_errors==1,
    'late metadata overwrote a conflicting local book')
host,state=fixture();UI.refresh(host,{book_id='900001'},nil,{automatic=true});job,books=state()
books['900001']=nil;job.cb(job.task())
local _,removed_books,removed_shown,removed_saves,removed_flushes,removed_errors=state()
expect(removed_books['900001']==nil and not removed_shown and removed_saves==0
    and removed_flushes==0 and removed_errors==1,'late metadata resurrected a removed book')
host,state=fixture();books=select(2,state());books['900001']={book_id='900002'}
expect(not UI.refresh(host,{book_id='900001'},nil,{automatic=true}) and not host.book_metadata_context
    and select(1,state())==nil and select(6,state())==1,'pre-existing identity conflict started a request')
host,state=fixture();UI.refresh(host,{book_id='900001'},nil,{automatic=true});job,books=state()
local string_record=books['900001'];local numeric_record={book_id='900001',title='Legacy'}
books[900001]=numeric_record;job.cb(job.task())
local _,duplicate_books,duplicate_shown,duplicate_saves,duplicate_flushes,duplicate_errors=state()
expect(duplicate_books['900001']==string_record and duplicate_books[900001]==numeric_record
    and not duplicate_shown and duplicate_saves==0 and duplicate_flushes==0 and duplicate_errors==1,
    'metadata chose between duplicate legacy indices')
host,state=fixture();UI.refresh(host,{book_id='900001'},nil,{automatic=true});job,books=state()
local legacy=books['900001'];books[900001]=legacy;books['900001']=nil;job.cb(job.task())
local _,migrated,migrated_book,migrated_saves=state()
expect(migrated_saves==1 and migrated[900001]==nil and migrated['900001']==migrated_book
    and migrated_book.cached_file=='existing.epub' and migrated_book.progress==83,
    'metadata refresh lost an unambiguous legacy numeric record')
host,state=fixture();local changing_selected_book={book_id='900001',bookId='900001'}
UI.refresh(host,changing_selected_book,nil,{automatic=true});job=state();changing_selected_book.bookId='900002';job.cb(job.task())
expect(select(4,state())==0 and not host.book_metadata_context,
    'metadata ignored a changed secondary book identity')
for _,change in ipairs({'page_replaced','page_closed','document','session','detail'}) do
    host,state=fixture();host.shelf_view={};host.ui={document={}};host._reader_session_gen=1
    expect(UI.refresh(host,{book_id='900001'},nil,{automatic=true}),'metadata scope fixture did not start')
    job=state()
    if change=='page_replaced' then host.shelf_view={}
    elseif change=='page_closed' then host.shelf_view._shelf_closed=true
    elseif change=='document' then host.ui.document={}
    elseif change=='session' then host._reader_session_gen=2
    else host._book_detail_view={} end
    job.cb(job.task())
    local _,_,late_book,late_saves=state()
    expect(not late_book and late_saves==0 and not host.book_metadata_context and not host.busy_message,
        'late metadata crossed a changed '..change)
end
for _,change in ipairs({"cookie","epoch","owner","cancel"}) do
    local alter
    host,state,alter=fixture()
    UI.refresh(host,{book_id="900001"},nil,{automatic=true})
    job=state()
    if change=="cookie" then cookies={wr_vid="900000",wr_skey="different-synthetic-access"}
    elseif change=="epoch" then host.discovery_epoch=2
    elseif change=="owner" then alter{owner="account-b"}
    else host.cancel_busy() end
    job.cb({metadata=source,source="web"})
    local _,_,_,written=state()
    expect(written==0 and not host.book_metadata_context and not host.busy_message,"cancelled/old metadata was saved")
end
local alter
host,state,alter=fixture();alter{online=false}
expect(not UI.refresh(host,{book_id="900001"},nil,{automatic=true}),"offline metadata started")
local task,_,offline_book,_,_,_,qr=state()
expect(task==nil and offline_book.book_id=="900001" and qr==0,"offline cache prompted a login")
host,state=fixture();valid=false
UI.refresh(host,{book_id="900001"},nil,{automatic=true})
local _,_,_,_,_,_,qr_count=state()
expect(qr_count==1,"unverified account did not request login")
host,state,alter=fixture();alter{signed_out=true};valid=false
expect(UI.refresh(host,{book_id="900001",title="Public title"},nil,{automatic=true}),
    "guest public metadata did not start")
job=state();job.cb(job.task())
local _,guest_books,guest_book,guest_saves,_,_,guest_qr=state()
expect(guest_book and guest_book.title==source.title and guest_book.detail_source=='public'
    and guest_book.progress==83 and not guest_book.token and guest_saves==0 and guest_qr==0,
    "guest public detail failed, changed reading state, saved to account DB or prompted login")
expect(guest_books['900001'].detail_source=='public','public metadata was not saved for guest offline use')
expect(UI.refresh(host,guest_book,nil,{}),'explicit guest refresh did not start')
job=state();job.cb(job.task())
local _,_,_,_,_,_,manual_qr=state()
expect(manual_qr==0,'public metadata refresh unexpectedly requested login')
host,state,alter=fixture();alter{signed_out=true};valid=false
UI.refresh(host,{book_id='900001'},nil,{automatic=true});job=state();local guest_result=job.task()
alter{owner='account-b'};job.cb(guest_result)
local _,_,stale_book,stale_saves=state()
expect(not stale_book and stale_saves==0 and not host.book_metadata_context,
    'guest metadata crossed an account change')
host,state,alter=fixture();alter{signed_out=true};valid=false
UI.refresh(host,{book_id='900001'},nil,{automatic=true});job=state();guest_result=job.task()
alter{auth_epoch=1};job.cb(guest_result)
local _,_,stale_epoch_book=state()
expect(not stale_epoch_book and not host.book_metadata_context,'guest metadata crossed a login epoch')
host,state,alter=fixture();alter{signed_out=true};valid=false
UI.refresh(host,{book_id='900001',title='Cached'},nil,{automatic=true});job=state();job.cb({metadata={bookId='wrong',title='Other'},source='public'})
local _,_,fallback_public,_,_,_,fallback_qr=state()
expect(fallback_public.title=='Cached' and fallback_qr==0 and not host.book_metadata_context,
    'failed public metadata lost cached details or prompted login')
host,state,alter=fixture();alter{signed_out=true};valid=false
UI.refresh(host,{book_id='900001',title='Cached'},nil,{automatic=true});job=state()
job.cb({metadata=source,source='native'})
local _,_,foreign_source,foreign_saves=state()
expect(foreign_source.title=='Cached' and foreign_saves==0,
    'guest accepted metadata from a non-public source')
host,state,alter=fixture();alter{signed_out=true};valid=false
host.settings.flush=function() error('synthetic save failure') end
UI.refresh(host,{book_id='900001',title='Cached'},nil,{automatic=true});job=state();job.cb(job.task())
local _,_,failed_public,_,_,guest_errors=state()
expect(failed_public and failed_public.title=='Cached' and guest_errors==1
    and not host.busy_message and not host.book_metadata_context,
    'guest storage failure lost the cached view or retained the worker')
host,state=fixture()
host.library_db.putBook=function() return false end
UI.refresh(host,{book_id="900001"},nil,{automatic=true})
job,books=state();local before_failure=books['900001'];job.cb(job.task())
local _,_,_,_,failed_flushes,save_errors=state()
expect(failed_flushes==0 and save_errors==1 and before_failure.title=='Old title'
    and before_failure.detail_updated_at==nil and not host.book_metadata_context and not host.busy_message,
    "failed SQLite save flushed metadata or retained busy state")
host,state=fixture()
host.book_metadata_worker.start=function() return false end
expect(not UI.refresh(host,{book_id="900001"},nil,{automatic=true}),"failed subprocess start reported success")
local _,_,fallback_book=state()
expect(fallback_book.book_id=="900001" and not host.book_metadata_context and not host.busy_message,
    "unavailable subprocess lost cached detail or retained busy state")

-- A Web 401 is recoverable once, bound to the same detail request and account.
local pending, renewals, renewal_cancels = nil, 0, 0
local revision = function() return string.rep(cookies.wr_skey == 'renewed-synthetic' and 'a' or 'b', 64) end
package.loaded['weread.lib.web_authorization'] = {capture=function() return {revision=revision(),scope=scope} end}
package.loaded['weread.ui.web_renewal'] = {
    run=function(_host,options,callback)
        renewals=renewals+1;pending={guard=options.is_current,callback=callback,expected=options.expected_revision}
        return true,pending
    end,
    cancel=function(_host,request)
        if request==pending then pending=nil;renewal_cancels=renewal_cancels+1 end
    end,
}
local function expired_fixture(gateway)
    pending,renewals,renewal_cancels=nil,0,0
    local sample,get_state,change=fixture()
    if gateway then key='synthetic-gateway-key' end
    local status='book_metadata/web_expired'
    local calls=0
    sample.client.get_display_book_metadata=function(_self,id,access)
        calls=calls+1
        if status then error(status,0) end
        return {bookId=id,title='Renewed details',author=access.kind}
    end
    local selected={book_id='900001',title='Cached title'}
    expect(UI.refresh(sample,selected,nil,{automatic=true}), 'metadata recovery did not start')
    return sample,get_state,change,selected,function(value) status=value end,function() return calls end
end
local function run_job(get_state) local work=get_state();work.cb(work.task()) end
local function complete_renewal(receipt)
    local request=assert(pending);pending=nil;cookies={wr_vid='900000',wr_skey='renewed-synthetic'}
    request.callback(true,receipt or {revision=revision()})
end
local update, selected, set_status, calls
host,state,_,_,set_status,calls=expired_fixture();run_job(state)
expect(renewals==1 and pending and pending.expected==string.rep('b',64) and pending.guard(),
    'Web 401 did not start a revision-bound renewal')
set_status(nil);complete_renewal();run_job(state)
local _,_,renewed_book,renewed_saves=state()
expect(renewed_saves==1 and renewed_book.title=='Renewed details' and calls()==2 and renewals==1
    and not host.book_metadata_context and not host.busy_message,'renewed Web details were not displayed')
host,state,_,_,set_status,calls=expired_fixture(true);run_job(state)
expect(calls()==2 and pending,'gateway fallback did not reach Web recovery')
set_status(nil);complete_renewal();run_job(state)
expect(calls()==3 and select(4,state())==1 and select(3,state()).author=='web' and not host.book_metadata_context,
    'Web recovery repeated the gateway request or failed to commit Web details')
host,state,_,_,_,calls=expired_fixture();run_job(state);complete_renewal();run_job(state)
local _,_,cached_book,second_saves=state()
expect(renewals==1 and calls()==2 and second_saves==0 and cached_book.title=='Cached title'
    and not host.book_metadata_context,'second 401 retried or lost cached details')
host,state,_,_,set_status,calls=expired_fixture();set_status('book_metadata/unavailable');run_job(state)
expect(renewals==0 and calls()==1 and not host.book_metadata_context,'non-401 failure started renewal')
host,state,_,_,_,calls=expired_fixture();run_job(state)
local failed_request=pending;pending=nil;failed_request.callback(false,'renewal_unconfirmed')
local _,_,failed_book,failed_saves=state()
expect(failed_saves==0 and failed_book.title=='Cached title' and calls()==1 and not host.book_metadata_context,
    'unconfirmed renewal retried or lost cached details')
host,state,_,_,_,calls=expired_fixture();run_job(state)
complete_renewal({revision=string.rep('f',64)})
expect(select(4,state())==0 and calls()==1 and not host.book_metadata_context,'foreign renewal receipt was accepted')
for _,change in ipairs({'cancel','account','epoch','book','offline','view'}) do
    host,state,update,selected,_,calls=expired_fixture()
    if change=='view' then
        UI.cancel(host);local view={};host._book_detail_view=view
        expect(UI.refresh(host,selected,view,{automatic=true}),'detail view refresh did not start')
    end
    run_job(state);local old=assert(pending)
    if change=='cancel' then host.cancel_busy()
    elseif change=='account' then update{owner='account-b'}
    elseif change=='epoch' then host.discovery_epoch=2
    elseif change=='book' then selected.book_id='900002'
    elseif change=='offline' then update{online=false}
    else host._book_detail_view={} end
    old.callback(true,{revision=string.rep('a',64)})
    expect(select(4,state())==0 and calls()==1 and not host.book_metadata_context and not host.busy_message,
        'stale metadata renewal was applied: '..change)
end
print("PASS: "..checks.." metadata projection/routing/async ownership/local-state checks")

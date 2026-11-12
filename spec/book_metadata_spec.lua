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
    local owner,online="account-a",true
    local original_get=settings.get
    local local_settings={get=function(_self,name,default)
        if name=="books" then return books end
        return original_get(settings,name,default)
    end,get_auth_scope=settings.get_auth_scope,auth_scope_matches=settings.auth_scope_matches,
        set=function(_self,name,value) expect(name=="books","metadata changed another setting") books=value end,
        flush=function() flushed=flushed+1 end}
    local host={settings=local_settings,discovery_epoch=1,
        client={settings=local_settings,get_display_book_metadata=function(_self,id) local copy={} for k,v in pairs(source) do copy[k]=v end copy.bookId=id return copy end},
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
        function(value) owner=value.owner or owner; if value.online~=nil then online=value.online end end
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
host,state=fixture()
host.library_db.putBook=function() return false end
UI.refresh(host,{book_id="900001"},nil,{automatic=true})
job=state();job.cb(job.task())
local _,_,_,_,failed_flushes,save_errors=state()
expect(failed_flushes==0 and save_errors==1 and not host.book_metadata_context and not host.busy_message,
    "failed SQLite save flushed metadata or retained busy state")
host,state=fixture()
host.book_metadata_worker.start=function() return false end
expect(not UI.refresh(host,{book_id="900001"},nil,{automatic=true}),"failed subprocess start reported success")
local _,_,fallback_book=state()
expect(fallback_book.book_id=="900001" and not host.book_metadata_context and not host.busy_message,
    "unavailable subprocess lost cached detail or retained busy state")
print("PASS: "..checks.." metadata projection/routing/async ownership/local-state checks")

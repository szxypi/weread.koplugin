package.path='./?.lua;'..package.path
local Navigation=require('weread.lib.source_navigation')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Coordinates=require('weread.lib.source_coordinates')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label or ('check '..checks)) end
local function clone(value)
    if type(value)~='table' then return value end
    local result={};for key,item in pairs(value) do result[key]=clone(item) end;return result
end
local raw='<html><body><p>ABCDE😀&amp;中文FGHIJKLMNOPQRST</p></body></html>'
local book,chapter={book_id='synthetic-nav',bookVersion=7},{chapterUid=11}
local path='OEBPS/text/chapter.xhtml'
local source=assert(Source.capture(book,chapter,raw,'web_xhtml'))
local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(raw))
local identity=assert(Identity.decode(root))
local metadata=assert(Source.bind(source,identity,path,Crypto.sha256_hex(raw)))
local target={book_id=book.book_id,chapter_uid='11',chapter_offset=32,file_id=identity.file_id,
    book_version=7,raw_sha256=source.raw_sha256,render_path=path,basis='filtered_xhtml_utf16',upload_verified=false}
local anchor=assert(assert(Coordinates.build(raw)):anchor(32))
local function fixture()
    local clock,queue=0,{}
    local function document()
        return {file='/book.epub',page=1,pos=0,
            getDocumentFileContent=function(_self,name)
                if name==Identity.PATH then return root end
                if name==Source.meta_path(11) or name==Source.path_meta_path(path) then return metadata end
                error('body read on UI thread')
            end,
            getCurrentPage=function(self) return self.page end,getCurrentPos=function(self) return self.pos end,
            getPageXPointer=function(self) return '/body/DocFragment/body/p/text().'..self.page end,
            getNormalizedXPointer=function(_self,xp) return xp end,isXPointerInCurrentPage=function() return true end}
    end
    local doc=document()
    local account,available,busy='owner',true,false
    local scheduler={scheduleIn=function(_self,delay,fn) queue[#queue+1]={at=clock+delay,fn=fn} end,
        unschedule=function(_self,fn) for i=#queue,1,-1 do if queue[i].fn==fn then table.remove(queue,i) end end end}
    local function step()
        table.sort(queue,function(a,b) return a.at<b.at end)
        local item=assert(table.remove(queue,1),'missing timer');clock=item.at;item.fn()
    end
    local function drain() local n=0;while #queue>0 do n=n+1;assert(n<30,'timer loop');step() end end
    local worker={jobs={},cancel=function(self) if self.active then self.active.cancelled=true end;self.active=nil end}
    function worker:start(task,callback)
        self.active={task=task,callback=callback};self.jobs[#self.jobs+1]=self.active;return true
    end
    local starts,done,moves,binds,results=0,0,0,{},{}
    local native_yield=false
    local nav
    local dom={open_prepared=function(candidate_document,candidate_book,meta,options)
        assert(candidate_document==doc and candidate_book==book.book_id and meta==metadata)
        if native_yield then options.yield() end
        assert(options.is_current())
        return {locate_anchor=function(_self,quote)
            assert(quote.text==anchor.text and quote.co==32)
            return {xpointer='/body/DocFragment/body/p/text().12',co=32,book_id=book.book_id,
                chapter_uid='11',file_id=identity.file_id,render_path=path}
        end}
    end}
    nav=Navigation:new{scheduler=scheduler,worker=worker,dom=dom,now=function() return clock end,
        get_document=function() return doc end,get_book_id=function() return book.book_id end,get_account=function() return account end,
        can_prepare=function() return available end,is_busy=function() return busy end,
        on_start=function() starts=starts+1 end,on_done=function() done=done+1 end,
        navigate=function() moves=moves+1;doc.page,doc.pos=8,800;nav:on_view_changed();return true end,
        on_applied=function(position,xp,meta) binds[#binds+1]={position=position,xp=xp,metadata=meta};return true end}
    local function jump(value)
        return nav:jump(value or target,function(position,reason) results[#results+1]={position=position,reason=reason} end)
    end
    local function packet()
        return {position=clone(target),anchor=clone(anchor),request_id=nav.sequence}
    end
    return {nav=nav,worker=worker,doc=doc,jump=jump,packet=packet,step=step,drain=drain,queue=queue,
        results=results,binds=binds,counters=function() return starts,done,moves end,
        account=function(value) account=value end,available=function(value) available=value end,
        busy=function(value) busy=value end,yield_native=function() native_yield=true end,
        advance=function(value) clock=clock+value end,reopen=function() doc=document() end}
end
local f=fixture()
expect(f.jump(),'valid target rejected');f.drain()
expect(#f.worker.jobs==1 and f.nav.state=='preparing','target worker not launched')
local response=f.packet();response.position.raw='BODY_CANARY';response.anchor.raw='SOURCE_CANARY'
f.worker.jobs[1].callback(response);f.drain()
expect(f.nav.state=='ready' and #f.binds==1 and #f.results==1,'target did not apply exactly once')
expect(f.results[1].position.chapter_offset==32 and not f.results[1].position.raw and not f.results[1].position.text,'body escaped result filter')
expect(f.binds[1].metadata==metadata and not f.nav.job,'binding lost immutable metadata or retained DOM job')
local started,done,moves=f.counters()
expect(started==1 and done==1 and moves==1,'navigation/pause lifecycle was not balanced')
for _,change in ipairs({{basis='catalog_words'},{file_id=string.rep('b',64)},{chapter_offset=0/0},
    {chapter_uid='22'},{raw_sha256=string.rep('a',64)},{book_id='other'},{upload_verified=true}}) do
    local bad=clone(target);for key,value in pairs(change) do bad[key]=value end
    local invalid=fixture();expect(not invalid.jump(bad) and #invalid.worker.jobs==0,'invalid/foreign target started work')
end
for _,mutation in ipairs({'account','page','reopen','timeout','backward_clock'}) do
    local stale=fixture();assert(stale.jump());stale.drain()
    local old=stale.worker.jobs[1];local packet=stale.packet()
    if mutation=='account' then stale.account('new-owner')
    elseif mutation=='page' then stale.doc.page=2
    elseif mutation=='reopen' then stale.reopen()
    elseif mutation=='timeout' then stale.advance(121)
    else stale.advance(-1) end
    stale.nav:on_view_changed();old.callback(packet);stale.drain()
    local _,ended,navigated=stale.counters()
    expect(old.cancelled and ended==1 and navigated==0 and #stale.results==0,'stale target committed: '..mutation)
end
for _,field in ipairs({'position','co','quote','point_offset','request_id'}) do
    local invalid=fixture();assert(invalid.jump());invalid.drain()
    local packet=invalid.packet()
    if field=='position' then packet.position=true
    elseif field=='co' then packet.anchor.co=999
    elseif field=='quote' then packet.anchor.text=string.rep('x',8193)
    elseif field=='point_offset' then packet.anchor.point_offset=-1
    else packet.request_id=999 end
    invalid.worker.jobs[1].callback(packet);invalid.drain()
    expect(invalid.nav.state=='unavailable' and #invalid.binds==0,'malformed worker packet accepted: '..field)
end
local yielding=fixture();yielding.yield_native();assert(yielding.jump());yielding.drain()
yielding.worker.jobs[1].callback(yielding.packet());yielding.step()
expect(yielding.nav.job.thread,'native lookup did not yield cooperatively')
yielding.doc.page=3;yielding.nav:on_view_changed();yielding.drain()
local _,_,navigated=yielding.counters()
expect(navigated==0 and not yielding.nav.job,'cancelled native lookup navigated')
local deferred=fixture();deferred.available(false);assert(deferred.jump());deferred.step()
expect(deferred.nav.state=='deferred' and #deferred.worker.jobs==0,'resource pressure spawned a worker')
deferred.available(true);deferred.drain()
expect(#deferred.worker.jobs==1,'resource recovery did not launch target preparation')
deferred.nav:cancel()
local unavailable=fixture();unavailable.available(false);assert(unavailable.jump());unavailable.drain()
expect(unavailable.nav.state=='unavailable' and #unavailable.queue==0,'resource retry was unbounded')
local selected=fixture();selected.busy(true);assert(selected.jump());selected.step()
expect(selected.nav.state=='deferred','highlight interaction was not deferred')
selected.nav:cancel()
local refused=fixture();refused.nav.navigate=function() return false end;assert(refused.jump());refused.drain()
refused.worker.jobs[1].callback(refused.packet());refused.drain()
expect(refused.nav.state=='unavailable' and #refused.binds==0,'native rejection was treated as successful navigation')
local failed=fixture();failed.nav.dom.open_prepared=function() error('private native diagnostic') end
assert(failed.jump());failed.drain();failed.worker.jobs[1].callback(failed.packet());failed.drain()
expect(failed.results[1].reason=='target_unavailable','private native diagnostic escaped controller')
local owned=fixture();local cancelled=0
owned.nav.on_cancel=function(job) assert(job and job.scope);cancelled=cancelled+1 end
assert(owned.jump());owned.drain();owned.nav:cancel();owned.nav:cancel()
expect(cancelled==1,'navigation cancellation did not notify its owner once')
owned=fixture();cancelled=0;owned.nav.on_cancel=function() cancelled=cancelled+1 end
assert(owned.jump());owned.drain();owned.worker.jobs[1].callback(owned.packet());owned.drain()
expect(owned.nav.state=='ready' and cancelled==0,'successful navigation used cancellation cleanup')
print(('source_navigation_spec: %d checks'):format(checks))

-- luacheck: ignore 311
package.path='./?.lua;' .. package.path
local queue,workers={},{}
package.preload['ui/uimanager']=function() return {scheduleIn=function(_self,delay,fn) assert(delay>=0.1);queue[#queue+1]=fn end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function(doc) return doc.identity end} end
package.preload['weread.lib.source_context']=function() return {
    location=function(doc) return {page=doc.page} end,same_location=function(a,b) return a and b and a.page==b.page end} end
package.preload['weread.lib.memory_worker']=function() return {new=function()
    local worker={cancel=function(self) self.cancelled=true end,start=function(self,task,callback)
        self.task,self.callback=task,callback;return true end}
    workers[#workers+1]=worker;return worker
end} end
local M=require('weread.ui.chapter_links')
local History=require('weread.lib.chapter_link_history')
local count=0
local function expect(value,message) count=count+1;assert(value,message) end
local function pump() local tasks=queue;queue={};for _i,fn in ipairs(tasks) do fn() end end
local function setup()
    queue,workers={},{}
    local state={owner='owner',epoch=1,opens=0,messages=0,cancels=0,downloads=0,native=0}
    local files={['/a.epub']={uid='1',id=string.rep('a',64)},['/b.epub']={uid='2',id=string.rep('b',64)}}
    local book={bookId='900001',chapters={{chapterUid=1,files={'body.xhtml'}},{chapterUid=2,files={'notes.xhtml'}}},
        cached_chapters={['1']='/a.epub',['2']='/b.epub'}}
    local client={json_encode=function(_self,value)
        local function encode(item)
            if type(item)~='table' then return tostring(item) end
            local out={};for _i,child in ipairs(item) do out[#out+1]=encode(child) end;return table.concat(out,'|')
        end
        return encode(value)
    end}
    local settings={get_book=function() return book end,get_auth_scope=function() return {epoch=state.epoch} end,
        auth_scope_matches=function(_self,auth) return auth and auth.epoch==state.epoch end}
    local make
    make=function(path)
        local record=assert(files[path]);local doc={file=path,page=1,identity={chapter_count=1,file_id=record.id}}
        function doc:isXPointerInDocument(xp) return type(xp)=='string' and (xp:sub(1,1)=='/' or xp:match('^#_doc_fragment_0_ '))~=nil end
        local host={_current_weread_book_id='900001',_reader_session_gen=1,settings=settings,client=client,
            library_db={accountKey=function() return state.owner end},ui={document=doc,view={view_mode='page'}}}
        local rolling={xpointer='/body/start'};host.ui.rolling=rolling
        function rolling:onGotoXPointer(xp) self.xpointer=xp end
        function rolling:onGotoPage(page) doc.page=page;self.xpointer='/body/page' .. page end
        local link={location_stack={},forward_location_stack={}};host.ui.link=link
        function link:getCurrentLocation() return {xpointer=rolling.xpointer} end
        function link:compareLocationToCurrent(loc) return loc.xpointer==rolling.xpointer end
        function link:onGotoLink() state.native=state.native+1;return 'native' end
        function link:onGoBackLink() state.native=state.native+1;return 'native' end
        function link:onGoForwardLink() state.native=state.native+1;return 'native' end
        host.progress_sync={navigation_generation=0,checkpoint_local=function() state.checkpoints=(state.checkpoints or 0)+1 end,
            begin_file_resume_departure=function() end,begin_file_resume=function(self) self.navigation_generation=1;return {} end,
            finish_file_resume=function(_self,_frame,applied) state.applied=applied end}
        function host:getChapterInfoFromFile(_book,file)
            for index,chapter in ipairs(book.chapters) do if book.cached_chapters[tostring(chapter.chapterUid)]==file then return index,chapter,false end end
        end
        function host:showBusy(_text,cancel) self.busy_message={};state.cancel=cancel end
        function host:closeBusy() self.busy_message=nil end
        function host:showTransientInfo() state.messages=state.messages+1 end
        host.downloader={cancelRequest=function() state.cancels=state.cancels+1 end,
            start=function(_self,_book,chapters,suffix,options)
                expect(chapters[1].chapterUid==2 and suffix=='chapter' and options.single_chapter and options.silent_completion and not options.offer_read,'existing single chapter producer not used')
                state.downloads=state.downloads+1;state.download_callback=options.on_complete
                return state.download_started~=false
            end}
        function host:openFile(target,callback)
            state.opens=state.opens+1;M.detach(self);self._reader_session_gen=self._reader_session_gen+1
            local child=make(target);state.child=child;M.attach(child)
            callback({weread=child,document=child.ui.document,rolling=child.ui.rolling,link=child.ui.link})
        end
        return host
    end
    local host=make('/a.epub');expect(M.attach(host),'standalone hooks missing')
    local function click() return host.ui.link:onGotoLink({xpointer='OEBPS/text/notes.xhtml#note',from_xpointer='/body/link'}) end
    local function ready()
        return {kind='ready',source_sha256=string.rep('c',64),target_uid='2',target_path='/b.epub',
            target_file_id=files['/b.epub'].id,target_sha256=string.rep('d',64),anchor='literal%2A'}
    end
    return host,state,book,click,ready,files
end
local host,state,book,click,ready=setup()
expect(click()==true and state.opens==0,'link did not await worker')
workers[1].callback(ready())
expect(state.opens==1 and state.child.ui.rolling.xpointer=='#_doc_fragment_0_ literal%2A','literal target not applied')
expect(state.applied and state.child.progress_sync.verified~=true,'local link must not grant cloud verification')
local target,index=History.candidate(state.child.ui.link,'back')
expect(target and index==1 and target.location.xpointer=='/body/start','source return frame lost')
expect(target.sha256==string.rep('c',64) and target.location.marker_xpointer=='/body/link','source receipt/marker missing')
local child=state.child
child.ui.link:onGoBackLink()
expect(state.opens==1 and #child.ui.link.location_stack==1,'Back mutated stacks before validation')
workers[2].callback({kind='ready',source_sha256=string.rep('d',64),target_uid='1',target_path='/a.epub',target_file_id=string.rep('a',64)})
expect(state.opens==2 and state.child.ui.rolling.xpointer=='/body/start','Back exact native location failed')
expect(History.candidate(state.child.ui.link,'forward').path=='/b.epub','reverse boundary missing')
state.child.ui.link:onGoForwardLink()
workers[3].callback(ready())
expect(state.opens==3 and state.child.ui.rolling.xpointer=='#_doc_fragment_0_ literal%2A','Forward lost exact target')

host,state,book,click,ready=setup();click();local stale=workers[1];click();stale.callback(ready())
expect(host._chapter_link_job and not workers[2].cancelled and state.opens==0,'stale callback cancelled newer navigation')
workers[2].callback(ready());expect(state.opens==1,'newer valid navigation lost')
for _i,change in ipairs({'page','marker','account','auth','catalog','cache','identity','session','document'}) do
    host,state,book,click,ready=setup();click()
    if change=='page' then host.ui.document.page=2
    elseif change=='marker' then host.ui.rolling.xpointer='/body/moved'
    elseif change=='account' then state.owner='other'
    elseif change=='auth' then state.epoch=2
    elseif change=='catalog' then book.chapters[2].files={'changed.xhtml'}
    elseif change=='cache' then book.cached_chapters['1']='/changed.epub'
    elseif change=='identity' then host.ui.document.identity.file_id=string.rep('e',64)
    elseif change=='session' then host._reader_session_gen=2
    elseif change=='document' then host.ui.document={} end
    workers[1].callback(ready())
    expect(state.opens==0 and not host._chapter_link_job,'stale ' .. change .. ' opened target')
end
host,state,book,click,ready=setup();click();host.ui.document.page=2;M.view_changed(host)
expect(workers[1].cancelled and not host._chapter_link_job,'movement did not cancel own worker')
host,state,book,click,ready=setup();click();state.cancel();workers[1].callback(ready())
expect(state.opens==0 and not host._chapter_link_job,'explicit cancel opened target')
host,state,book,click,ready=setup();click();workers[1].callback({kind='unavailable'})
expect(state.opens==0 and state.messages==1,'unverified target opened')
host,state,book,click,ready=setup();book.cached_chapters['2']=nil;click()
workers[1].callback({kind='needs_download',target_uid='2'})
expect(state.downloads==1 and state.opens==0,'missing target did not await existing downloader')
book.cached_chapters['2']='/b.epub';state.download_callback(true);pump()
expect(#workers==1 and workers[1].task and state.opens==0,'download completion skipped revalidation')
workers[1].callback(ready());expect(state.opens==1,'reverified downloaded chapter not opened')
host,state,book,click,ready=setup();click();workers[1].callback({kind='needs_download',target_uid='2'});M.cancel(host)
state.download_callback(true);pump();expect(state.opens==0 and state.cancels==1,'owned downloader cancellation failed')
host,state,book,click,ready=setup();click();workers[1].callback({kind='needs_download',target_uid='2'});state.download_callback(false);pump()
expect(state.opens==0 and state.messages==1,'failed download opened target')
host,state,book,click,ready=setup();state.download_started=false;click();workers[1].callback({kind='needs_download',target_uid='2'})
expect(state.opens==0 and not host._chapter_link_job,'busy downloader left navigation pending')
host,state,book,click,ready=setup();click();workers[1].callback({kind='needs_download',target_uid='2'});state.download_callback(true);pump()
workers[1].callback({kind='needs_download',target_uid='2'})
expect(state.downloads==1 and state.messages==1,'unverified download was blindly retried')
host,state,book,click,ready=setup()
expect(host.ui.link:onGotoLink({xpointer='https://example.org/book'})=='native','external URL claimed')
expect(host.ui.link:onGotoLink({xpointer='#_doc_fragment_0_ local'})=='native','local native link claimed')
local wrapper=host.ui.link.onGotoLink;local later=function() end;host.ui.link.onGotoLink=later;M.detach(host)
expect(host.ui.link.onGotoLink==later,'detach removed later third party handler')
expect(wrapper(host.ui.link,{xpointer='OEBPS/text/notes.xhtml#note'})=='native','detached stale handler retained ownership')
host,state,book,click,ready=setup();book.chapters[4]={chapterUid=4,files={'notes.xhtml'}}
expect(click()=='native' and not host._chapter_link_job,'sparse source catalog was silently projected')
host,state,book,click,ready=setup();book.chapters[2].files={[2]='notes.xhtml'}
expect(click()=='native' and not host._chapter_link_job,'sparse source paths were silently projected')
host,state,book,click,ready=setup();click();local detached=workers[1];M.detach(host);detached.callback(ready())
expect(state.opens==0 and detached.cancelled,'closed source accepted a late worker result')
host,state,book,click,ready=setup();click();workers[1].callback(ready());local target_host=state.child
local boundary_before=#target_host.ui.link.location_stack
target_host.ui.link:onGoBackLink();workers[2].callback({kind='unavailable'})
expect(state.opens==1 and #target_host.ui.link.location_stack==boundary_before,'failed return consumed native history')
expect(target_host.ui.link:onGoBackLink()==true,'failed return could not be retried')
local nested_limit={back={},forward={},location={xpointer='/old'}}
for n=1,100 do nested_limit={back={History.marker({xpointer='/old'},nested_limit)},forward={},location={xpointer='/old'}} end
local limited=select(1,History.stacks({location_stack={History.marker({xpointer='/now'},nested_limit)},forward_location_stack={}}))
local depth=0
while #limited>0 do
    local node=History.candidate({location_stack=limited,compareLocationToCurrent=function() return false end},'back')
    if not node then break end
    depth=depth+1;limited=node.back
end
expect(depth==History.MAX_FRAMES,'cross-file memory history is not bounded')
local saved={xpointer='/one'};local nested={back={},forward={},location=saved}
local link={location_stack={{xpointer='/old'},History.marker(saved,nested),{xpointer='/same'}},forward_location_stack={},
    compareLocationToCurrent=function(_self,value) return value.xpointer=='/same' end}
local boundary,index2=History.candidate(link,'back')
expect(boundary==nested and index2==2,'same-page top hid cross-file boundary')
local back,forward=History.stacks(link,'back',index2)
expect(#back==1 and #forward==0 and #link.location_stack==3,'history snapshot mutated live stack')
print('chapter_links_spec: ' .. count .. ' checks passed')

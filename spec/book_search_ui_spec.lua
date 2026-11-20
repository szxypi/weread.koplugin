package.path='./?.lua;'..package.path
local displayed
local UI={}
function UI:show(widget) displayed=widget end
function UI:close(widget) if widget and widget.onCloseWidget then widget:onCloseWidget() end end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/inputdialog']=function() return {new=function(_self,options)
    function options:onShowKeyboard() end
    function options:getInputText() return self.input end
    return options
end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.ui.shelf_popup']=function() return {redraw=function(_owner,callback) callback() end,
    show=function(owner,dialog) owner._shelf_popup=dialog;return true end,
    current=function(owner,dialog) return owner._shelf_popup==dialog end,
    close=function(owner) if owner then owner._shelf_popup=nil end end} end
package.preload['ui/widget/menu']=function() return {new=function(_self,options)
    function options:switchItemTable(_title,items) self.item_table=items end
    return options
end} end
local access={web={cookies={}},revision='a'};local access_current=true
package.preload['weread.lib.read_access']=function() return {capture=function() return access end,
    display_book_id=function(id) return type(id)=='string' and (id:match('^[1-9]%d*$') or id:match('^CB_[A-Za-z0-9]+$')) and id or nil end,
    matches=function() return access_current end} end
local navigation_calls=0
package.preload['weread.ui.my_mark_navigation']=function() return {
    start=function(target_host,owner,row,current) assert(current(target_host,owner));navigation_calls=navigation_calls+1;owner.navigation={row=row} end,
    cancel=function(_host,owner) owner.navigation=nil end,
} end
package.preload['weread.ui.book_reading']=function() return {catalog=function(rows) return rows end} end
local fetched_catalog={{chapterUid='1',title='First'},{chapterUid='2',title='Second'}}
local saved_catalogs,catalog_saves,allow_catalog_save,allow_db_save=0,0,true,true
package.preload['weread.lib.worker_settings']=function() return {
    fingerprint=function() return 'synthetic' end,capture=function() return function() return nil end end,
    merge=function() return true end,
} end
package.preload['weread.lib.content']=function() return {
    ensure_reader_state=function() end,fetch_catalog=function() return fetched_catalog end,
    save_catalog_cache=function() catalog_saves=catalog_saves+1;return allow_catalog_save end,
} end
package.preload['weread.lib.book_search_target']=function() return {row=function(book,hit)
    if hit.source_verified~=false then return nil end
    return {bookId=book,chapterUid=tonumber(hit.chapter_uid),markText=hit.text,type=1,range='1-3'}
end} end
local fetch_mode='ok';local fetches=0
package.preload['weread.lib.book_search']=function() return {
    new=function(book,keyword,chapters,first)
        local uid=first or tostring(chapters[1].chapterUid)
        local present,order=false,{};for i,row in ipairs(chapters) do
            local id=tostring(row.chapterUid);order[id]=i;if id==uid then present=true end
        end
        if not present then return nil end
        return {book=book,keyword=keyword,pages=0,finished=false,chapters=chapters,cursor={chapter=uid},
            order=order,seen={},hit_count=0}
    end,
    fetch=function(_client,state)
        fetches=fetches+1
        if fetch_mode=='fail' then return nil,'unavailable' end
        if fetch_mode=='expired' then return nil,'web_http_401' end
        if fetch_mode=='business_expired' then return nil,'web_expired' end
        if fetch_mode=='limited' then return nil,'rate_limited' end
        if fetch_mode=='empty' then state.pages=state.pages+1;state.finished=true;return {hits={},finished=true} end
        if fetch_mode=='last_page' then state.pages=128;state.finished=true;return {hits={},finished=true} end
        if fetch_mode=='fallback' and state.cursor.chapter=='1' then
            state.pages=state.pages+1;state.finished=true;return {hits={},finished=true}
        end
        if fetch_mode=='merge' or fetch_mode=='interleave' then
            local candidates
            if fetch_mode=='interleave' then
                state.step=(state.step or 0)+1
                if state.cursor.chapter=='1' and state.step==1 then
                    candidates={{chapter_uid='2',start=30,finish=34}};state.finished=false
                elseif state.cursor.chapter=='1' then
                    candidates={{chapter_uid='2',start=30,finish=34},{chapter_uid='2',start=50,finish=54}};state.finished=true
                elseif state.step==1 then
                    candidates={{chapter_uid='2',start=10,finish=14},{chapter_uid='2',start=30,finish=34}};state.finished=false
                else candidates={{chapter_uid='2',start=40,finish=44}};state.finished=true end
            elseif state.cursor.chapter=='1' then
                candidates={{chapter_uid='2',start=30,finish=34}};state.finished=true
            elseif state.pages==1 then
                candidates={{chapter_uid='2',start=10,finish=14},{chapter_uid='2',start=30,finish=34}}
                state.finished=false
            else candidates={{chapter_uid='2',start=40,finish=44}};state.finished=true end
            local hits={}
            for _i,hit in ipairs(candidates) do
                local key=hit.chapter_uid..':'..hit.start..':'..hit.finish
                if not state.seen[key] then
                    state.seen[key]=true;state.hit_count=state.hit_count+1
                    hit.text='term';hit.context='term context';hit.source_verified=false;hits[#hits+1]=hit
                end
            end
            state.pages=state.pages+1;return {hits=hits,finished=state.finished}
        end
        state.pages=state.pages+1;state.finished=state.pages==2
        return {hits={{chapter_uid=fetch_mode=='fallback' and state.cursor.chapter or '1',start=1,finish=5,text='term',
            context=string.rep('long prefix ',20)..'term context',source_verified=false}},finished=state.finished}
    end,
} end
local pending_renewal,renewals,cancellations=nil,0,0
local synchronous_renewal=false
package.preload['weread.ui.web_renewal']=function() return {
    run=function(_host,options,callback)
        renewals=renewals+1;pending_renewal={guard=options.is_current,callback=callback}
        if synchronous_renewal then fetch_mode='ok';callback(true) end
        return true,pending_renewal
    end,
    cancel=function(_host,request) if request then cancellations=cancellations+1 end end,
    error_text=function(reason) return 'renewal error: '..tostring(reason) end,
} end
local active_worker
package.preload['weread.lib.memory_worker']=function() return {new=function()
    local worker={}
    function worker:start(task,callback) self.task,self.callback=task,callback;active_worker=self;return true end
    function worker:cancel() self.cancelled=true end
    function worker:complete() local value=self.task();self.callback(value) end
    return worker
end} end

local Search=require('weread.ui.book_search')
local cached_calls,cached_request,cached_available=0,nil,true
package.preload['weread.ui.cached_book_search']=function() return {open=function(target,id,rows,keyword)
    cached_calls=cached_calls+1;cached_request={host=target,id=id,rows=rows,keyword=keyword};return cached_available
end} end
local checks=0
local function expect(value,label) checks=checks+1;if not value then error(label) end end
local account='123';local online=true;local scope_valid=true;local has_scope=true
local host={ui={document={file='/synthetic.epub'}},_reader_session_gen=1,
    settings={get_auth_scope=function() return has_scope and {vid='123',epoch=1} or nil end,
        auth_scope_matches=function() return scope_valid end,get_book=function() return {book_id='CB_Synthetic'} end},
    library_db={accountKey=function() return account end,putChapters=function(_self,_id,_chapters)
        saved_catalogs=saved_catalogs+1;return allow_db_save
    end},client={}}
function host:isNetworkOnline() return online end
function host:showOffline() self.info='offline' end
function host:showInfo(value) self.info=value end
function host:showBusy(_value,cancel) self.busy_message={cancel=cancel} end
function host:closeBusy() self.busy_message=nil end
function host:showList(_title,items)
    local menu={items=items}
    function menu.switchItemTable(widget,_new_title,next_items) widget.items=next_items end
    return menu
end
local chapters={{chapterUid='1',title='Chapter'}}
local function open_and_submit()
    assert(Search.open(host,'100',chapters));local input=assert(displayed)
    input.input='term';input.buttons[1][2].callback()
    return assert(host._book_search_owner)
end
local function downloaded_action(owner)
    for _i,item in ipairs(owner.menu.items) do if item.text=='Search downloaded chapters' then return item end end
end

online=false;expect(Search.open(host,'100',chapters) and cached_calls==1 and cached_request.id=='100'
    and cached_request.rows==chapters and not host._book_search_owner,'offline entry did not open downloaded search')
account=nil;scope_valid=false
expect(Search.open(host,'100',chapters) and cached_calls==2,'offline entry incorrectly required an online account')
account='123';scope_valid=true
cached_available=false
expect(not Search.open(host,'100',chapters) and host.info=='offline','unavailable offline search had no explanation')
cached_available=true;cached_calls=0
online=true
scope_valid=false;expect(not Search.open(host,'100',chapters)
    and cached_calls==0 and host.info=='A verified WeRead web login is required for online book search.',
    'invalid account scope was not blocked')
scope_valid=true
account=nil;has_scope=false
expect(Search.open(host,'100',chapters) and cached_calls==1 and cached_request.id=='100',
    'signed-out search did not open downloaded chapters')
cached_available=false
expect(not Search.open(host,'100',chapters)
    and host.info=='A verified WeRead web login is required for online book search.',
    'missing login and cache had no explanation')
cached_available=true;cached_calls=0;account='123';has_scope=true
local web_access=access.web;access.web=nil
expect(Search.open(host,'100',chapters) and cached_calls==1,'missing Web credentials did not open downloaded chapters')
cached_calls=0;access.web=web_access
local cancelled_owner=open_and_submit();local cancelled_worker=active_worker
host.busy_message.cancel()
local cancelled_local=downloaded_action(cancelled_owner)
expect(not cancelled_owner.job and cancelled_local,'cancelled first search did not offer downloaded chapters')
cancelled_local.callback()
expect(cached_calls==1 and cached_request.id=='100' and cached_request.rows==chapters and cached_request.keyword=='term',
    'cancelled first search did not preserve its query and chapter list')
cancelled_worker:complete()
expect(cancelled_owner.state.pages==0 and #cancelled_owner.value==0,'cancelled first search accepted a late response')
cached_calls=0;Search.cancel(host)
local owner=open_and_submit()
expect(owner.state.pages==0 and owner.job~=nil,'first page did not start asynchronously')
active_worker:complete()
expect(owner.state.pages==1 and #owner.value==1 and #owner.menu.items==3,
    'first page did not populate native results and next-page action')
expect(owner.menu.items[3].text:find('term',1,true)~=nil,'a long excerpt hid the search term')
local successful_local=owner.menu.items[2]
expect(successful_local.text=='Search downloaded chapters','ordinary results did not offer downloaded search')
successful_local.callback()
expect(cached_calls==1 and cached_request.id=='100' and cached_request.keyword=='term' and #owner.value==1,
    'local search lost the query or changed the online results')
cached_calls=0
owner.menu.items[1].callback();expect(owner.state.pages==1 and owner.job~=nil,'pagination changed state before its worker returned')
successful_local.callback();expect(cached_calls==0,'local search started while pagination was active')
active_worker:complete()
expect(owner.state.pages==2 and owner.state.finished and #owner.value==2 and #owner.menu.items==3,
    'second page did not append results and remove the next-page action')
owner.menu.items[2].callback()
expect(navigation_calls==1 and owner.navigation.row.bookId=='100','search result did not start verified navigation')
Search.cancel(host)
expect(not host._book_search_owner and not owner.navigation,'closing search did not cancel navigation')
successful_local.callback();expect(cached_calls==0,'closed search started downloaded search')

fetch_mode='empty';owner=open_and_submit();active_worker:complete()
expect(owner.state.finished and #owner.value==0 and owner.menu.items[1].text=='No matching text found.'
    and owner.menu.items[2].text=='Search downloaded chapters', 'empty ordinary results lacked local search')
owner.menu.items[2].callback();expect(cached_calls==1 and cached_request.keyword=='term',
    'empty ordinary result did not pass its query to local search')
cached_calls=0;Search.cancel(host);fetch_mode='ok'

owner=open_and_submit();local old=active_worker;host.ui.document={file='/other.epub'};old:complete()
expect(not host._book_search_owner and #owner.value==0,'late response opened after switching documents')
host.ui.document={file='/synthetic.epub'}
owner=open_and_submit();active_worker:complete();fetch_mode='fail';owner.menu.items[1].callback();active_worker:complete()
expect(owner.state.pages==1 and #owner.value==1 and host.info=='Could not search this book. Check the network and try again.',
    'failed later page replaced already displayed results')
local offline_action
for _i,item in ipairs(owner.menu.items) do if item.text=='Search downloaded chapters' then offline_action=item end end
expect(offline_action~=nil,'failed online search did not offer downloaded chapters')
offline_action.callback()
expect(cached_calls==1 and cached_request.id=='100' and cached_request.keyword=='term',
    'failed online search did not preserve the query for downloaded search')
cached_calls=0
fetch_mode='ok';Search.cancel(host)
owner=open_and_submit();active_worker:complete();online=false;owner.menu.items[1].callback()
expect(owner.state.pages==1 and #owner.value==1 and host.info=='offline','disconnect discarded online search results')
offline_action=nil
for _i,item in ipairs(owner.menu.items) do if item.text=='Search downloaded chapters' then offline_action=item end end
expect(offline_action~=nil,'disconnect did not offer downloaded chapters')
offline_action.callback();expect(cached_calls==1 and cached_request.keyword=='term','disconnect fallback lost the query')
cached_calls=0;online=true;Search.cancel(host)
owner=open_and_submit();access_current=false;active_worker:complete();access_current=true
expect(owner.state.pages==0 and #owner.value==0 and not host._book_search_owner
    and host.info=='WeRead login changed. Search again.','changed authorization committed a stale response')
Search.cancel(host)
owner=open_and_submit();scope_valid=false;active_worker:complete();scope_valid=true
expect(not host._book_search_owner and #owner.value==0,'account change kept search work alive')

fetch_mode='expired';owner=open_and_submit();active_worker:complete()
local renewal=pending_renewal
expect(owner.recovery and renewal and renewal.guard() and owner.state.pages==0,'401 did not start scoped renewal')
local before=fetches;owner.menu.items[1].callback()
expect(fetches==before and not owner.job,'pagination ran while renewal was pending')
fetch_mode='ok';renewal.callback(true)
expect(not owner.recovery and owner.job and owner.state.pages==0,'successful renewal did not retry the same page')
active_worker:complete()
expect(owner.state.pages==1 and #owner.value==1,'renewed first page did not display once')
fetch_mode='expired';owner.menu.items[1].callback();active_worker:complete();renewal=pending_renewal
expect(owner.recovery and owner.state.pages==1 and #owner.value==1,'renewal discarded previous pages')
local nav_before=navigation_calls;owner.menu.items[3].callback()
expect(navigation_calls==nav_before and not owner.navigation,'result navigation ran during renewal')
fetch_mode='ok';renewal.callback(true);active_worker:complete()
expect(owner.state.pages==2 and #owner.value==2,'renewed later page repeated or lost results')
Search.cancel(host)
fetch_mode='expired';synchronous_renewal=true;owner=open_and_submit();active_worker:complete();synchronous_renewal=false
expect(owner.job and not owner.recovery,'synchronous renewal lost the replacement page worker')
active_worker:complete();expect(owner.state.pages==1 and #owner.value==1,'synchronous renewal failed to display results')
Search.cancel(host)

fetch_mode='expired';local before_renewals=renewals;owner=open_and_submit();active_worker:complete()
renewal=pending_renewal;renewal.callback(true);active_worker:complete()
expect(renewals==before_renewals+1 and not owner.recovery and owner.state.pages==0
    and host.info=='The search login is unavailable. Check your login and try again. Existing results are kept.',
    'repeated 401 caused another automatic renewal or hid the login problem')
owner.menu.items[1].callback();active_worker:complete()
expect(renewals==before_renewals+1 and not owner.recovery and owner.state.pages==0,
    'manual retry renewed the same failed page again')
Search.cancel(host)

owner=open_and_submit();active_worker:complete();renewal=pending_renewal;local cancelled_before=cancellations
host.busy_message.cancel()
expect(not owner.recovery and cancellations==cancelled_before+1,'cancel did not stop pending renewal')
local cancelled_renewal_local=downloaded_action(owner)
expect(cancelled_renewal_local~=nil,'cancelled renewal did not offer downloaded chapters')
cancelled_renewal_local.callback()
expect(cached_request.id=='100' and cached_request.rows==chapters and cached_request.keyword=='term',
    'cancelled renewal did not preserve its query and chapter list')
cached_calls=0
before=fetches;renewal.callback(true)
expect(fetches==before and not owner.job,'cancelled renewal restarted the search')
Search.cancel(host)

owner=open_and_submit();active_worker:complete();renewal=pending_renewal
host.ui.document={file='/other.epub'}
expect(not renewal.guard(),'renewal did not detect a switched document')
renewal.callback(false,'session_changed')
expect(not host._book_search_owner and not owner.job,'late renewal survived a document change')
host.ui.document={file='/synthetic.epub'}

owner=open_and_submit();active_worker:complete();renewal=pending_renewal;account='456'
expect(not renewal.guard(),'renewal did not detect an account change')
renewal.callback(false,'session_changed')
expect(not host._book_search_owner and not owner.job,'late renewal survived an account change')
account='123'

owner=open_and_submit();active_worker:complete();renewal=pending_renewal;cancelled_before=cancellations
Search.cancel(host)
expect(not owner.recovery and cancellations==cancelled_before+1 and not renewal.guard(),
    'closing search did not cancel and invalidate renewal')
before=fetches;renewal.callback(true)
expect(fetches==before and not host._book_search_owner,'closed search resumed after a late renewal')

fetch_mode='business_expired';before_renewals=renewals;owner=open_and_submit();active_worker:complete()
expect(renewals==before_renewals and not owner.recovery and owner.state.pages==0,
    'unverified business error triggered automatic renewal')
Search.cancel(host)
fetch_mode='limited';owner=open_and_submit();active_worker:complete()
expect(renewals==before_renewals and not owner.recovery
    and host.info=='Search requests are temporarily limited. Wait and try again. Existing results are kept.',
    'rate limiting triggered renewal or lacked an actionable message')
local rate_fallback
for _i,item in ipairs(owner.menu.items) do if item.text=='Search downloaded chapters' then rate_fallback=item end end
expect(rate_fallback~=nil,'rate-limited search did not offer downloaded chapters')
Search.cancel(host)
owner=open_and_submit();before_renewals=renewals
active_worker.callback({reason='web_http_401',page={},state={book='100',keyword='term',pages=0}})
expect(renewals==before_renewals and not owner.recovery and owner.state.pages==0,
    'malformed error packet triggered automatic renewal')
Search.cancel(host)
fetch_mode='ok';owner=open_and_submit();active_worker:complete();fetch_mode='expired';owner.menu.items[1].callback();active_worker:complete()
renewal=pending_renewal;renewal.callback(false,'renewal_unconfirmed')
expect(not owner.recovery and owner.state.pages==1 and #owner.value==1
    and host.info=='renewal error: renewal_unconfirmed','failed renewal discarded previous results')
local renewal_fallback
for _i,item in ipairs(owner.menu.items) do if item.text=='Search downloaded chapters' then renewal_fallback=item end end
expect(renewal_fallback~=nil,'failed login renewal did not offer downloaded chapters')
Search.cancel(host);fetch_mode='ok'
expect(Search.open(host,'CB_Synthetic',chapters),'imported book did not open online search')
local cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback()
local cb_owner=assert(host._book_search_owner);active_worker:complete()
expect(cb_owner.menu.items[#cb_owner.menu.items].text=='Search results may be incomplete for this book.',
    'imported book results did not disclose indexing limitations')
local offline
for _i,item in ipairs(cb_owner.menu.items) do if item.text=='Search downloaded chapters' then offline=item end end
expect(offline~=nil,'incomplete imported results did not offer downloaded search')
offline.callback()
expect(cached_calls==1 and cached_request.host==host and cached_request.id=='CB_Synthetic'
    and cached_request.rows==chapters and cached_request.keyword=='term','offline search lost its book, catalog or query')
Search.cancel(host)
offline.callback();expect(cached_calls==1,'closed online results launched downloaded search')
fetch_mode='empty';expect(Search.open(host,'CB_Synthetic',chapters),'imported book search did not reopen')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
active_worker:complete()
expect(cb_owner.menu.items[1].text=='No matches returned. Search may be incomplete for this book.',
    'empty imported search claimed a complete negative result')
offline=cb_owner.menu.items[2]
expect(offline and offline.text=='Search downloaded chapters','empty online result did not offer downloaded search')
scope_valid=false;offline.callback();scope_valid=true
expect(cached_calls==1,'changed account launched an old offline action')
offline.callback();expect(cached_calls==2 and cached_request.keyword=='term','empty-result fallback lost query')
Search.cancel(host)
expect(not Search.open(host,'CB_bad/path',chapters),'invalid imported book ID was accepted')
local two_chapters={{chapterUid='1',title='First'},{chapterUid='2',title='Second'}}
fetch_mode='fallback';expect(Search.open(host,'CB_Synthetic',two_chapters,'2'),'fallback search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
before=fetches;active_worker:complete()
expect(cb_owner.fallback_attempted and cb_owner.state.cursor.chapter=='2' and cb_owner.state.pages==1 and cb_owner.job,
    'empty first-chapter result did not launch a current-chapter query')
active_worker:complete()
expect(fetches==before+2 and cb_owner.state.pages==2 and #cb_owner.value==1 and cb_owner.value[1].chapter_uid=='2',
    'current-chapter fallback did not retain the bounded query count or result')
Search.cancel(host)
expect(Search.open(host,'CB_Synthetic',two_chapters,'1'),'same-chapter search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
before=fetches;active_worker:complete()
expect(fetches==before+1 and not cb_owner.fallback_attempted and not cb_owner.job,
    'same starting chapter caused a duplicate query')
Search.cancel(host)
expect(Search.open(host,'CB_Synthetic',two_chapters,'2'),'cancellation search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
active_worker:complete();local late=active_worker;Search.cancel(host);late:complete()
expect(not host._book_search_owner and #cb_owner.value==0,'cancelled fallback delivered a stale result')
fetch_mode='ok';expect(Search.open(host,'CB_Synthetic',two_chapters,'2'),'nonempty CB search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
before=fetches;active_worker:complete()
expect(fetches==before+1 and not cb_owner.fallback_attempted and #cb_owner.value==1,
    'nonempty first-chapter search triggered an unnecessary fallback')
Search.cancel(host)
fetch_mode='merge';expect(Search.open(host,'CB_Synthetic',two_chapters,'2'),'nonempty fallback did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
before=fetches;active_worker:complete()
expect(cb_owner.fallback_attempted and cb_owner.job and #cb_owner.value==1 and cb_owner.state.hit_count==1,
    'nonempty completed results did not start the current-chapter query')
active_worker:complete()
expect(fetches==before+2 and #cb_owner.value==2 and cb_owner.value[1].start==10 and cb_owner.value[2].start==30
    and cb_owner.state.hit_count==2 and not cb_owner.state.finished,
    'current-chapter results were not merged in order or duplicate ranges were repeated')
cb_owner.menu.items[1].callback();active_worker:complete()
expect(fetches==before+3 and cb_owner.state.finished and #cb_owner.value==3 and cb_owner.value[3].start==40,
    'supplemental pagination lost or repeated earlier results')
Search.cancel(host)
expect(Search.open(host,'CB_Synthetic',two_chapters,'2'),'failed supplemental search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
active_worker:complete();fetch_mode='fail';active_worker:complete()
expect(#cb_owner.value==1 and cb_owner.value[1].start==30 and cb_owner.state.pages==1
    and cb_owner.menu.items[1].text=='Load more results','failed supplemental request discarded first results or retry')
fetch_mode='merge';cb_owner.menu.items[1].callback();active_worker:complete()
expect(#cb_owner.value==2 and cb_owner.value[1].start==10,'supplemental retry lost results')
Search.cancel(host)
fetch_mode='interleave';expect(Search.open(host,'CB_Synthetic',two_chapters,'2'),'early supplemental search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
before=fetches;active_worker:complete()
local function action(label)
    for _i,item in ipairs(cb_owner.menu.items) do if item.text==label then return item end end
end
local early=assert(action('Search from current chapter'));early.callback()
expect(cb_owner.primary_state and cb_owner.job and cb_owner.state.pages==1,
    'early supplemental search discarded the first cursor or page count')
active_worker:complete()
expect(#cb_owner.value==2 and cb_owner.value[1].start==10 and cb_owner.state.hit_count==2,
    'early supplemental search did not merge and deduplicate')
local resume=assert(action('Continue original search'));resume.callback()
expect(not cb_owner.job and cb_owner.fallback_state and cb_owner.state.cursor.chapter=='1' and cb_owner.state.pages==2,
    'switching back discarded the supplemental cursor or changed the first cursor')
assert(action('Load more results')).callback();active_worker:complete()
expect(cb_owner.job and cb_owner.fallback_attempted and cb_owner.state.cursor.chapter=='2' and cb_owner.state.pages==3
    and #cb_owner.value==3,'first search did not resume or continue the unfinished supplement')
active_worker:complete()
expect(cb_owner.state.finished and cb_owner.state.pages==4 and cb_owner.state.hit_count==4 and #cb_owner.value==4
    and cb_owner.value[1].start==10 and cb_owner.value[2].start==30 and cb_owner.value[3].start==40
    and cb_owner.value[4].start==50 and fetches==before+4,'interleaved search lost order, limits, or results')
Search.cancel(host)
expect(Search.open(host,'CB_Synthetic',two_chapters,'2'),'cancelled early supplemental search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
active_worker:complete();assert(action('Search from current chapter')).callback()
local early_worker=active_worker;host.busy_message.cancel();assert(action('Continue original search')).callback()
early_worker:complete()
expect(cb_owner.state.cursor.chapter=='1' and cb_owner.state.pages==1 and #cb_owner.value==1,
    'cancelled supplemental response crossed into the resumed first search')
Search.cancel(host)
expect(Search.open(host,'CB_Synthetic',two_chapters,'2'),'failed early supplemental search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
active_worker:complete();assert(action('Search from current chapter')).callback()
fetch_mode='fail';active_worker:complete()
expect(#cb_owner.value==1 and cb_owner.state.pages==1 and action('Continue original search'),
    'failed early supplement discarded results or the first cursor')
assert(action('Continue original search')).callback()
expect(cb_owner.fallback_state and action('Search from current chapter'),'failed supplement could not be resumed')
fetch_mode='interleave';Search.cancel(host)
expect(Search.open(host,'CB_Synthetic',two_chapters,'2'),'bounded early supplemental search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
active_worker:complete();cb_owner.state.pages=127
assert(action('Search from current chapter')).callback();active_worker:complete()
expect(cb_owner.state.pages==128 and not cb_owner.job and not action('Load more results')
    and not action('Search from current chapter'),'switching cursors exceeded the shared page limit')
Search.cancel(host)
fetch_mode='interleave';expect(Search.open(host,'CB_Synthetic',two_chapters,'2'),'chapter selection search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
active_worker:complete()
local original,automatic=cb_owner.state,cb_owner.fallback_state
assert(action('Search from another chapter')).callback()
local picker=assert(cb_owner.menu._shelf_popup)
expect(#picker.item_table==2 and picker.item_table[2].text=='2. Second','chapter picker lost its catalog')
local stale_chapter=picker.item_table[2].callback;stale_chapter()
expect(cb_owner.manual_origin and cb_owner.state.cursor.chapter=='2' and cb_owner.state.pages==1 and cb_owner.job,
    'selected chapter did not start with shared budget and a saved original cursor')
active_worker:complete()
expect(#cb_owner.value==2 and cb_owner.value[1].start==10 and cb_owner.value[2].start==30
    and cb_owner.state.pages==2 and cb_owner.state.hit_count==2,
    'selected chapter failed to merge, order and deduplicate results')
assert(action('Return to previous search')).callback()
expect(cb_owner.state==original and cb_owner.fallback_state==automatic and cb_owner.state.pages==2
    and cb_owner.state.hit_count==2 and not cb_owner.manual_origin,
    'returning discarded the original or automatic supplemental cursor')
before=fetches;stale_chapter();expect(fetches==before and not cb_owner.job,'closed chapter picker dispatched stale selection')
assert(action('Load more results')).callback();active_worker:complete()
expect(cb_owner.job and cb_owner.state.cursor.chapter=='2' and #cb_owner.value==3,
    'original cursor did not resume and continue the automatic supplement')
active_worker:complete();assert(action('Load more results')).callback();active_worker:complete()
expect(cb_owner.state.finished and cb_owner.state.pages==5 and #cb_owner.value==4,
    'shared results or global page count changed after resuming both searches')
Search.cancel(host)

fetch_mode='interleave';expect(Search.open(host,'CB_Synthetic',two_chapters,'2'),'nested cursor search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
active_worker:complete();assert(action('Search from current chapter')).callback();active_worker:complete()
local supplement,original_cursor=cb_owner.state,cb_owner.primary_state
assert(action('Search from another chapter')).callback();picker=assert(cb_owner.menu._shelf_popup)
picker.item_table[1].callback();fetch_mode='fail';active_worker:complete()
expect(cb_owner.manual_origin and cb_owner.state.pages==2 and #cb_owner.value==2 and action('Return to previous search'),
    'failed selected-chapter search lost results or its return path')
assert(action('Return to previous search')).callback()
expect(cb_owner.state==supplement and cb_owner.primary_state==original_cursor and cb_owner.state.pages==2,
    'failed selected-chapter search discarded the suspended automatic cursor')
local limited_action=assert(action('Search from another chapter'));cb_owner.state.pages=128
before=fetches;limited_action.callback()
expect(not cb_owner.menu._shelf_popup and not cb_owner.job and fetches==before,
    'stale chapter action bypassed the shared page limit')
Search.cancel(host)

local many_chapters={};for i=1,43 do many_chapters[i]={chapterUid=tostring(i),title='Chapter '..i} end
fetch_mode='ok';expect(Search.open(host,'CB_Synthetic',many_chapters,'1'),'paged chapter search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
active_worker:complete();assert(action('Search from another chapter')).callback();picker=assert(cb_owner.menu._shelf_popup)
expect(#picker.item_table==41 and picker.item_table[41].text=='Next chapters','chapter picker did not bound its first page')
local stale_page_item=picker.item_table[1].callback;picker.item_table[41].callback();stale_page_item()
expect(#picker.item_table==4 and picker.item_table[1].text=='Previous chapters'
    and picker.item_table[2].text=='41. Chapter 41' and not cb_owner.manual_origin,
    'chapter picker did not advance correctly or accepted a stale row')
picker.item_table[2].callback();local chosen=active_worker
expect(cb_owner.state.cursor.chapter=='41' and cb_owner.manual_origin and cb_owner.job,'chapter on second page was not selected')
host.busy_message.cancel();assert(action('Return to previous search')).callback()
chosen:complete()
expect(cb_owner.state.cursor.chapter=='1' and cb_owner.state.pages==1 and #cb_owner.value==1,
    'cancelled chapter request changed restored results')
Search.cancel(host)
fetch_mode='fallback';expect(Search.open(host,'CB_Synthetic',two_chapters,'99'),'unknown-chapter search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
before=fetches;active_worker:complete()
expect(fetches==before+1 and not cb_owner.fallback_attempted and not cb_owner.job,
    'a chapter outside the catalog triggered fallback')
Search.cancel(host)
fetch_mode='last_page';expect(Search.open(host,'CB_Synthetic',two_chapters,'2'),'page-limit search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
cb_owner.state.pages=127;before=fetches;active_worker:complete()
expect(fetches==before+1 and not cb_owner.fallback_attempted and not cb_owner.job,
    'fallback exceeded the overall page limit')
Search.cancel(host)
fetch_mode='ok'
expect(Search.open(host,'CB_Synthetic',nil,'2'),'cancelled catalog search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
cancelled_worker=active_worker;host.busy_message.cancel()
local cancelled_catalog_local=downloaded_action(cb_owner)
expect(not cb_owner.job and cancelled_catalog_local,'cancelled catalog loading did not offer downloaded chapters')
cancelled_catalog_local.callback()
expect(cached_request.id=='CB_Synthetic' and cached_request.rows==nil and cached_request.keyword=='term',
    'cancelled catalog loading lost its local search scope')
local cancelled_saves=saved_catalogs;cancelled_worker:complete()
expect(not cb_owner.state and saved_catalogs==cancelled_saves,'cancelled catalog loading accepted a late response')
Search.cancel(host)
expect(Search.open(host,'CB_Synthetic',nil,'2'),'missing-catalog search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
local before_stored,before_saved=saved_catalogs,catalog_saves
active_worker:complete()
expect(saved_catalogs==before_stored+1 and catalog_saves==before_saved+1 and cb_owner.state and cb_owner.job,
    'fetched catalog was not persisted before search and navigation')
active_worker:complete();Search.cancel(host)
allow_catalog_save=false
expect(Search.open(host,'CB_Synthetic',nil,'2'),'save-failure search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
before=fetches;active_worker:complete()
expect(not cb_owner.state and not cb_owner.job and fetches==before
    and host.info=="Could not load this book's chapter list.",
    'failed catalog save continued into search')
local retry,local_fallback
for _i,item in ipairs(cb_owner.menu.items) do
    if item.text=='Retry search' then retry=item end
    if item.text=='Search downloaded chapters' then local_fallback=item end
end
expect(retry and local_fallback,'catalog failure did not retain retry and downloaded-search options')
local_fallback.callback()
expect(cached_request.keyword=='term' and cached_request.id=='CB_Synthetic',
    'catalog failure did not preserve the downloaded-search query')
allow_catalog_save=true;Search.cancel(host)
allow_db_save=false
expect(Search.open(host,'CB_Synthetic',nil,'2'),'database-failure search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
before_saved=catalog_saves;active_worker:complete()
expect(not cb_owner.state and not cb_owner.job and catalog_saves==before_saved,
    'database failure continued to file saving or search')
allow_db_save=true;Search.cancel(host)
expect(Search.open(host,'CB_Synthetic',nil,'2'),'stale-catalog search did not open')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();assert(host._book_search_owner)
before_stored,before_saved=saved_catalogs,catalog_saves;account='456';active_worker:complete();account='123'
expect(not host._book_search_owner and saved_catalogs==before_stored and catalog_saves==before_saved,
    'a stale catalog was persisted after the account changed')
print(('book_search_ui_spec: %d checks'):format(checks))

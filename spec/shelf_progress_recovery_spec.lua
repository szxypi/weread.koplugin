package.path='./?.lua;'..package.path
local renewals,cancelled,mode={},{},nil
package.preload['weread.ui.web_renewal']=function() return {
    run=function(host,options,callback)
        if mode=='busy' then return false,'busy' end
        local request={host=host,guard=options.is_current,callback=callback};renewals[#renewals+1]=request
        return true,request
    end,
    cancel=function(_host,request) cancelled[#cancelled+1]=request end,
    error_text=function() return 'Saved progress is kept.' end,
} end
local Progress=require('weread.ui.shelf_progress')
local Data=require('weread.lib.shelf_progress')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local ids={'900001','900002','900003'}
local worker_context={checkCancelled=function() end,emit=function() end}
local function fixture()
    renewals,cancelled,mode={},{},nil
    local state={jobs={},requests={},stopped={},writes={},cache={},redraws=0,account='owner',epoch=1,api='',
        cookies={wr_vid='900000',wr_skey='synthetic-old-access'},messages=0}
    local settings={cache_dir='/cache',get_auth_scope=function() return {vid='900000',epoch=state.epoch} end,
        auth_scope_matches=function(_self,value) return value.vid=='900000' and value.epoch==state.epoch end}
    function settings:get(key,default)
        if key=='cookies' then return state.cookies elseif key=='api_key' then return state.api elseif key=='books' then
            return {['900001']={progress=83,pending_upload_account='owner',pending_upload_position={percent=83}}}
        end
        return default
    end
    local worker={available=function() return true end,
        cancel=function(_self,request) state.stopped[#state.stopped+1]=request end,
        start=function(_self,options)
            if state.start_error then error('synthetic launch failure') end
            if state.start_false then return false end
            local request={options=options};state.jobs[#state.jobs+1]=request
            if state.on_start then state.on_start() end
            if state.sync_error then options.on_done({ok=false}) end
            return true,request
        end}
    local host=setmetatable({settings=settings,shelf_progress_worker=worker,ui={document={file='/one.epub'}},
        _reader_session_gen=1,discovery_epoch=1,shelf_view={},isNetworkOnline=function() return true end,
        showTransientInfo=function() state.messages=state.messages+1 end,
        library_db={accountKey=function() return state.account end,getShelfProgress=function() return state.cache end,
            putShelfProgress=function(_self,values)
                if state.storage_failed then return false end
                state.writes[#state.writes+1]=values
                for _,snapshot in ipairs(values) do state.cache[snapshot.book_id]=snapshot end
                return true
            end}}, {__index=Progress})
    host.client={settings=settings,get_shelf_display_progress=function(_self,id,access)
        state.requests[#state.requests+1]={id=id,kind=access.kind,cookie=access.cookies and access.cookies.wr_skey}
        if access.kind=='gateway' then error('display_progress/unavailable',0) end
        if id=='900002' and (state.cookies.wr_skey=='synthetic-old-access' or state.persistent) then error('display_progress/login',0) end
        if state.business then return {errCode=state.business} end
        return {book={bookId=id,progress=37}}
    end}
    function state:start()
        local books={};for _,id in ipairs(ids) do books[#books+1]={bookId=id} end
        host:refreshVisibleShelfProgress(host.shelf_view,books,{}, {force=true,on_redraw=function() self.redraws=self.redraws+1 end})
    end
    function state:complete(index)
        local request=self.jobs[index or #self.jobs]
        local value=request.options.task(worker_context)
        request.options.on_done({ok=true,value=value});return request,value
    end
    function state:renew(ok,reason)
        if ok then self.cookies={wr_vid='900000',wr_skey='synthetic-new-access'} end
        local request=renewals[#renewals];request.callback(ok,reason)
    end
    return host,state
end
local host,state=fixture();state:start()
local old,batch=state:complete()
expect(batch.web_expired and batch.next_index==2 and #batch.snapshots==1 and #state.requests==2,'login failure did not stop at a bounded valid prefix')
expect(#renewals==1 and state.cache[ids[1]].percent==37 and state.redraws==0,'prefix lost or renewal not owned before redraw')
expect(host.settings:get('books')[ids[1]].pending_upload_position.percent==83,'renewal replaced pending local position')
state:start();expect(#state.jobs==1 and #renewals==1,'same visible page duplicated pending renewal')
old.options.on_done({ok=true,value=batch});expect(#renewals==1 and host.shelf_progress_context.renewing,'duplicate callback ended renewal')
state:renew(true);expect(#state.jobs==2,'verified login did not resume display reads')
state:complete();expect(#state.requests==4 and state.requests[3].id==ids[2] and state.requests[4].id==ids[3]
    and state.requests[3].cookie=='synthetic-new-access','resumption replayed prefix or used stale cookies')
expect(state.redraws==1 and state.cache[ids[3]].percent==37 and #renewals==1,'resumption lost final cache or repeated renewal')
old.options.on_done({ok=true,value=batch});renewals[1].callback(true)
expect(#state.jobs==2 and #renewals==1 and state.redraws==1,'late callbacks restarted finished operation')

host,state=fixture();state.api='synthetic-gateway';state:start();state:complete();state:renew(true);state:complete()
local routes={};for _,request in ipairs(state.requests) do routes[#routes+1]=request.kind end
expect(table.concat(routes,',')=='gateway,web,web,web,web' and not host.shelf_progress_context.renewing,'resumed suffix retried failed gateway')

host,state=fixture();state.persistent=true;state:start();state:complete();state:renew(true);state:complete()
expect(#renewals==1 and #state.requests==3 and host.shelf_progress_retry_at and state.cache[ids[1]],'persistent 401 looped renewal or lost prefix')
local before=#state.jobs;state:start();expect(#state.jobs==before,'persistent 401 ignored failure wait')

for _,reason in ipairs({'renewal_unconfirmed','verification_unconfirmed','save_failed','busy'}) do
    host,state=fixture();mode=reason=='busy' and 'busy' or nil;state:start();state:complete()
    if reason~='busy' then state:renew(false,reason) end
    expect(#state.jobs==1 and state.cache[ids[1]] and state.redraws==1 and host.shelf_progress_retry_at,'failed renewal lost prefix or replayed: '..reason)
end

for _,change in ipairs({'account','epoch','session','document','file','cache','api'}) do
    host,state=fixture();state:start();state:complete();local request=renewals[1]
    if change=='account' then state.account='other' elseif change=='epoch' then state.epoch=2
    elseif change=='session' then host._reader_session_gen=2 elseif change=='document' then host.ui.document={file='/one.epub'}
    elseif change=='file' then host.ui.document.file='/two.epub' elseif change=='cache' then host.settings.cache_dir='/other'
    else state.api='replaced' end
    expect(not request.guard(),'old owner remained renewable: '..change)
    state:renew(true);expect(#state.jobs==1 and #state.writes==1,'changed owner resumed request: '..change)
end

host,state=fixture();state:start();state:complete();local request=renewals[1]
host:cancelShelfProgress();expect(cancelled[#cancelled]==request and not host.shelf_progress_context,'cancel failed to release its owned renewal')
request.callback(true);expect(#state.jobs==1,'cancelled renewal resumed')

host,state=fixture();state:start();state.storage_failed=true;state:complete()
expect(#renewals==0 and host.shelf_progress_retry_at,'storage failure sent credential maintenance')

host,state=fixture();state:start();state.jobs[1].options.on_done({ok=true,value={snapshots={},web_expired=true,next_index=99}})
expect(#renewals==0 and host.shelf_progress_retry_at,'malformed continuation triggered renewal')

for _,code in ipairs({-2010,-2041,-2012}) do
    host,state=fixture();state.business=code;state:start();state:complete()
    expect(#renewals==0 and #state.requests==1 and host.shelf_progress_retry_at,'unverified business error triggered renewal')
end

for _,failure in ipairs({'start_error','start_false','sync_error'}) do
    host,state=fixture();state:start();state:complete();state[failure]=true;state:renew(true)
    expect(host.shelf_progress_retry_at and state.redraws==1,'failed resumed launch hid prefix: '..failure)
    expect(not host.shelf_progress_context.request,'finished synchronous launch retained a request')
end

host,state=fixture();state.on_start=function() host.ui.document.file='/changed.epub' end;state:start()
expect(#state.stopped==1 and state.stopped[1]==state.jobs[1],'changed owner during launch left an unowned worker')

host,state=fixture();state:start();host.ui.document.file='/changed.epub';state:complete()
expect(#state.writes==0 and #renewals==0,'changed document applied old result')
state:start();expect(#state.jobs==2,'stale completed context prevented a fresh view read')

local client={settings=host.settings,get_shelf_display_progress=function() error('display_progress/login',0) end}
local access=assert(Data.selection(host.settings))
local value=Data.fetch(client,ids,worker_context,access,{web_only=true})
expect(value.web_expired and value.next_index==1 and #value.snapshots==0,'explicit Web continuation lost login classification')
print('PASS: visible progress once-only renewal, suffix continuation and owner/cancellation guards ('..checks..' checks)')

-- Native local ledger review. No authentication, HTTP or transfer mutations.
local C=require('weread.lib.readtime_transfer_contract')
local Queue=require('weread.lib.readtime_transfer_queue')
local Coverage=require('weread.lib.readtime_coverage')
local UI=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}
local STATUS={recording='Recording offline reading',online='Online; offline recording is idle',disabled='Disabled',paused='Paused',
    no_book='Open a WeRead book to record time',reader_hidden='Return to the reading page to record time',
    book_mismatch='This file does not match the reading book; time is not recorded',unsupported_book='Offline time recording is unavailable for public-account articles',
    account_unavailable='Log in to associate offline reading time',statistics_unavailable='Enable KOReader Reading statistics to record time',
    clock_unavailable='Device clock is unavailable',clock_changed='Device clock changed; recording is waiting',
    storage_error='Could not save offline reading time',storage_unavailable='Could not save offline reading time',
    ledger_full='Offline reading time storage is full',network_unavailable='Waiting for a known network state'}
local STATES={pending='Pending local records',in_flight='Checking saved time',unknown='Uncertain time records',covered='Covered time records'}
local function close_field(host,key)
    local widget=host[key];host[key]=nil
    if widget then UI:close(widget) end
end
function M.close(host)
    local context=host._offline_time_review;host._offline_time_review=nil
    if host.offline_time_review_worker then host.offline_time_review_worker:cancel() end
    if context and context.busy and host.busy_message==context.busy then host:closeBusy() end
    close_field(host,'_offline_time_detail');close_field(host,'_offline_time_menu')
end
local function owns(host,context)
    return host._offline_time_review==context and host.library_db:accountKey()==context.account
        and (host.discovery_epoch or 0)==context.epoch and (host.ui and host.ui.document)==context.document
        and host._reader_session_gen==context.session
        and (not context.auth_checked or context.auth and host.settings:auth_scope_matches(context.auth))
end
local function title(host,id)
    local book=host.library_db:getBook(id);local text=type(book)=='table' and book.title
    if type(text)~='string' or text=='' then return _('Unknown book') end
    local chars={};local count=0
    for char in text:gsub('[%c]+',' '):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        count=count+1;if count>60 then chars[#chars+1]='…';break end;chars[#chars+1]=char
    end
    return #chars>0 and table.concat(chars) or _('Unknown book')
end
local function time_label(row)
    local ok=pcall(require('weread.lib.readtime_protocol').zone,row.time_zone)
    if not ok then return _('Time needs verification') end
    local z=row.time_zone;local offset=(tonumber(z:sub(2,3))*60+tonumber(z:sub(5,6)))*60*(z:sub(1,1)=='-' and -1 or 1)
    local valid,value=pcall(os.date,'!%Y-%m-%d %H:%M:%S',row.start_time+offset)
    return valid and type(value)=='string' and value..' '..z or _('Time needs verification')
end
local function seconds(value) return T(_('%1 s'),tostring(value)) end
local load
local function dialog(host,context,text,back)
    close_field(host,'_offline_time_detail')
    local widget
    widget=require('ui/widget/buttondialog'):new{title=text,tap_close_callback=function()
        if host._offline_time_detail==widget then host._offline_time_detail=nil;M.close(host) end
    end,buttons={{
        {text=_('Back'),callback=function()
            if host._offline_time_detail~=widget then return end
            if not owns(host,context) then M.close(host);return end
            close_field(host,'_offline_time_detail');back()
        end},
        {text=_('Close'),callback=function() if host._offline_time_detail==widget then M.close(host) end end},
    }}}
    host._offline_time_detail=widget;UI:show(widget)
end
local function menu(host,context,name,items)
    close_field(host,'_offline_time_menu')
    local widget
    for _i,item in ipairs(items) do
        if item.callback then
            local callback=item.callback
            item.callback=function()
                if host._offline_time_menu~=widget then return end
                if not owns(host,context) then M.close(host);return end
                close_field(host,'_offline_time_menu');callback()
            end
        else item.select_enabled=false end
    end
    widget=host:showList(name,items,nil,{items_per_page=8})
    host._offline_time_menu=widget
    if widget then widget.close_callback=function()
        if host._offline_time_menu==widget then host._offline_time_menu=nil;M.close(host) end
    end end
end
local function render(host,context,kind,value,args)
    if kind=='summary' then
        local summary=value.summary;local state=STATUS[context.error or context.state] or 'Could not save offline reading time'
        menu(host,context,_('Offline reading time'),{
            {text=_(state)},
            {text=_('Pending local records'),mandatory=seconds(summary.pending),callback=function() load(host,context,'page',{category='pending',cursors={0},index=1}) end},
            {text=_('Uncertain time records'),mandatory=seconds(summary.unknown+summary.in_flight),callback=function() load(host,context,'page',{category='review',cursors={0},index=1}) end},
            {text=_('Covered time records'),mandatory=seconds(summary.covered),callback=function() load(host,context,'page',{category='covered',cursors={0},index=1}) end},
            {text=_('Confirmed transferred time'),mandatory=seconds(summary.confirmed)},
            {text=_('Check saved time'),callback=function() load(host,context,'selection',{}) end},
            {text=_('Refresh local records'),callback=function() M.show(host) end},
            {text=_('Offline time stays on this device until cloud transfer is available.')},
        })
    elseif kind=='page' then
        local page=value.page;local items={}
        args.upper_id=page.upper_id
        for _i,entry in ipairs(page.rows) do
            items[#items+1]={text=time_label(entry.source)..'\n'..entry.title,mandatory=seconds(entry.source.duration),
                callback=function() load(host,context,'detail',{entry=entry,back=args}) end}
        end
        if #items==0 then items[1]={text=_('No saved time in this category.')} end
        if args.index>1 then items[#items+1]={text=_('Previous batch'),callback=function()
            args.index=args.index-1;load(host,context,'page',args)
        end} end
        if page.has_more then items[#items+1]={text=_('Next batch'),callback=function()
            args.cursors[args.index+1]=page.last_id;args.index=args.index+1;load(host,context,'page',args)
        end} end
        items[#items+1]={text=_('Offline reading time'),callback=function() load(host,context,'summary',{}) end}
        menu(host,context,_(args.category=='review' and 'Uncertain time records' or args.category=='covered' and 'Covered time records' or 'Pending local records'),items)
    elseif kind=='detail' then
        local entry=value.entry;local row=entry.source
        local text=entry.title..'\n'..time_label(row)..'\n'..T(_('Duration: %1'),seconds(row.duration))
            ..'\n'.._(STATES[entry.state])..'\n'.._(C.verified(row,os.time()) and 'Captured download source is available' or 'Download source needs verification')
        if entry.state=='pending' then
            text=text..'\n'..T(_('Known covered time: %1'),seconds(value.coverage.covered))
                ..'\n'..T(_('Time before coverage tracking: %1'),seconds(value.coverage.unverified))
        end
        if entry.conflict then text=text..'\n'.._('Overlapping local time is kept for review.') end
        if entry.state=='unknown' or entry.state=='in_flight' then text=text..'\n'.._('Uncertain records are kept and will not be sent again automatically.') end
        dialog(host,context,text,function() load(host,context,'page',args.back) end)
    elseif kind=='selection' then
        local chosen=value.selection
        local text=chosen and value.title..'\n'..T(_('Local duplicate check: %1'),seconds(chosen.seconds))
            ..'\n'..time_label(chosen.protocol_rows[1]) or _('No locally verified time is available in this check.')
        dialog(host,context,text..'\n\n'.._('Offline time stays on this device until cloud transfer is available.'),
            function() load(host,context,'summary',{}) end)
    end
end
load=function(host,context,kind,args)
    if not owns(host,context) then M.close(host);return end
    close_field(host,'_offline_time_detail');close_field(host,'_offline_time_menu')
    if host.offline_time_review_worker then host.offline_time_review_worker:cancel() end
    local operation={};context.operation=operation
    host:showBusy(_('Reading saved time...'),function() if owns(host,context) then M.close(host) end end)
    context.busy=host.busy_message
    local function fail()
        M.close(host);host:showInfo(_('Could not read saved time. The records are kept.'))
    end
    if not host.offline_time_review_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=256*1024} end)
        if not ok then fail();return end;host.offline_time_review_worker=worker
    end
    local ledger=host.offline_time.store;local coverage=host.readtime_coverage or Coverage:new(host.settings.data_dir)
    local ran,started=pcall(host.offline_time_review_worker.start,host.offline_time_review_worker,function()
        if kind=='summary' then return {summary=assert(ledger:summary(context.account))} end
        if kind=='page' then
            local page=assert(ledger:review_page(context.account,args.category,args.cursors[args.index],args.upper_id,20))
            for _i,entry in ipairs(page.rows) do entry.title=title(host,entry.source.book_id) end
            return {page=page}
        end
        if kind=='detail' then
            local original=args.entry.source
            local page=assert(ledger:review_page(context.account,'all',original.id-1,original.id,1));local entry=assert(page.rows[1])
            assert(C.digest(entry.source)==C.digest(original),'changed');entry.title=title(host,entry.source.book_id)
            return {entry=entry,coverage=assert(coverage:preview_individual(context.account,{entry.source}))}
        end
        local result=assert(Queue:new{ledger=ledger,coverage=coverage}:select(context.account))
        result.title=result.selection and title(host,result.selection.book_id) or nil;return result
    end,function(value)
        if not owns(host,context) or context.operation~=operation then
            if host._offline_time_review==context and context.operation==operation then M.close(host) end
            return
        end
        if context.busy and host.busy_message==context.busy then host:closeBusy() end;context.busy=nil
        if type(value)~='table' or value.error then fail();return end
        local ok=pcall(render,host,context,kind,value,args)
        if not ok then fail() end
    end)
    if not ran or not started then fail() end
end
function M.show(host)
    host:closeWeReadUI()
    if not host.offline_time or not host.library_db then return end
    local account=host.library_db:accountKey()
    if not C.account(account) then host:showInfo(_('Log in to associate offline reading time'));return end
    host.offline_time:update('status')
    local context={account=account,epoch=host.discovery_epoch or 0,session=host._reader_session_gen,
        document=host.ui and host.ui.document,state=host.offline_time.state,error=host.offline_time.error,
        auth_checked=host.settings.get_auth_scope~=nil,
        auth=host.settings.get_auth_scope and host.settings:get_auth_scope()}
    if context.auth_checked and not context.auth then host:showInfo(_('Log in to associate offline reading time'));return end
    host._offline_time_review=context;load(host,context,'summary',{})
end
return M

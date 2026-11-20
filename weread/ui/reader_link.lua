-- Native Reader-link input, background verification, and offline imported list.
local Link=require('weread.lib.reader_link')
local Store=require('weread.lib.reader_link_store')
local UIManager=require('ui/uimanager')
local PluginUtil=require('weread.lib.plugin_util')
local _=PluginUtil.tr
local M={}
local function storage(host) return Store:new(host.library_db,host.client) end
local function account(host) return host.library_db and host.library_db:accountKey() end
local function close_view(host,key)
    local widget=host[key];host[key]=nil
    if widget then UIManager:close(widget) end
end
function M.cancel(host)
    local job=host.reader_link_context;host.reader_link_context=nil
    if not job then return end
    if host.reader_link_worker then host.reader_link_worker:cancel() end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
function M.close(host)
    M.cancel(host)
    for _,key in ipairs({'_reader_link_confirm','_reader_link_actions','_reader_link_menu','_reader_link_input'}) do close_view(host,key) end
end
local function scope(host)
    return {account=account(host),epoch=host.discovery_epoch or 0,document=host.ui and host.ui.document,
        session=host._reader_session_gen}
end
local function same_scope(host,context)
    return account(host)==context.account and (host.discovery_epoch or 0)==context.epoch
        and (host.ui and host.ui.document)==context.document and host._reader_session_gen==context.session
end
local function owns(host,context) return context.account and same_scope(host,context) end
local function open_record(host,record,owner)
    if not owns(host,owner) then return false end
    local valid,bounded=pcall(Link.record,record)
    if not valid then return false end
    host:closeWeReadUI()
    if account(host)~=owner.account then return false end
    local book=bounded.metadata
    book.book_id=book.bookId
    book.reader_url=bounded.reader_url
    book.detail_updated_at=record.imported_at or os.time();book.detail_source='web'
    host:showBookRecord(book,{verified_metadata=true})
    return true
end
function M.start(host,url,refresh)
    M.close(host)
    url=Link.canonical(url)
    if not url then host:showInfo(_('Use a standard HTTPS WeRead book reading link.'));return false end
    local owner=scope(host)
    if not owner.account then host:requireLogin(true,false);return false end
    if not refresh then
        local cached=storage(host):find(url)
        if cached then return open_record(host,cached,owner) end
    end
    local access=Link.capture(host.settings)
    if not access or not access.web then
        host:showTransientInfo(_('Please scan the QR code to log in first.'),2)
        if host.qr_login then UIManager:scheduleIn(0.2,function() if owns(host,owner) then host.qr_login:start() end end) end
        return false
    end
    if not host:isNetworkOnline() then host:showOffline(_('Import reader link'));return false end
    local job=owner;job.access=access;job.started=os.time()
    host.reader_link_context=job
    local function current()
        local age=os.time()-job.started
        return host.reader_link_context==job and owns(host,job) and Link.matches(host.settings,access) and age>=0 and age<=120
    end
    host:showBusy(_('Importing reader link...'),function() if host.reader_link_context==job then M.cancel(host) end end)
    job.busy=host.busy_message
    local function failed()
        if host.reader_link_context==job then M.cancel(host) end
        host:showInfo(_('Could not verify this reader link. Saved links are kept.'))
    end
    if not host.reader_link_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client,max_bytes=256*1024} end)
        if not ok then failed();return false end
        host.reader_link_worker=worker
    end
    local ok,started=pcall(host.reader_link_worker.start,host.reader_link_worker,function()
        local valid,record=pcall(Link.fetch,host.client,url,access)
        return valid and record or {error='unavailable'}
    end,function(record)
        if not current() then if host.reader_link_context==job then M.cancel(host) end return end
        local valid,bounded=pcall(Link.record,record)
        if not valid or bounded.reader_url~=url then failed();return end
        if not storage(host):put(bounded) then
            M.cancel(host);host:showInfo(_('Could not save this reader link. Check storage and try again.'));return
        end
        bounded.imported_at=os.time()
        M.cancel(host)
        if open_record(host,bounded,owner) then host:showTransientInfo(_('Reader link saved on this device.'),2) end
    end)
    if not ok or not started then failed();return false end
    return true
end
function M.input(host)
    host:closeWeReadUI()
    local owner=scope(host)
    local dialog
    local function dismiss()
        if host._reader_link_input~=dialog then return false end
        close_view(host,'_reader_link_input');return true
    end
    dialog=require('ui/widget/inputdialog'):new{
        title=_('Paste WeRead reader URL'),input='https://weread.qq.com/web/reader/',input_type='text',
        buttons={{
            {text=_('Cancel'),id='close',callback=dismiss},
            {text=_('Import reader link'),is_enter_default=true,callback=function()
                if not same_scope(host,owner) then dismiss();return end
                local url=dialog:getInputText();if dismiss() then M.start(host,url) end
            end},
        },{{text=_('Imported books'),callback=function() if dismiss() and same_scope(host,owner) then M.list(host,0) end end}}},
    }
    host._reader_link_input=dialog
    host:showInputDialog(dialog)
end
local function menu(host,key,title,rows)
    local widget=host:showList(title,rows)
    host[key]=widget
    if widget then widget.close_callback=function() if host[key]==widget then host[key]=nil end end end
    return widget
end
function M.actions(host,id,page)
    M.close(host)
    local owner=scope(host)
    local record=storage(host):get(id)
    if not record or not owner.account then host:showInfo(_('Saved reader link is unavailable.'));return end
    local widget
    local function choose(callback)
        return function()
            if host._reader_link_actions~=widget or not owns(host,owner) then return end
            close_view(host,'_reader_link_actions');callback()
        end
    end
    widget=menu(host,'_reader_link_actions',record.metadata.title,{
        {text=_('Open book'),callback=choose(function() open_record(host,record,owner) end)},
        {text=_('Refresh imported book'),callback=choose(function() M.start(host,record.reader_url,true) end)},
        {text=_('Remove imported book'),callback=choose(function()
            local confirm
            confirm=require('ui/widget/confirmbox'):new{keep_dialog_open=true,
                text=_('Remove this entry from imported books? Downloaded files and your cloud bookshelf are kept.'),
                ok_text=_('Remove'),cancel_text=_('Cancel'),
                cancel_callback=function() if host._reader_link_confirm==confirm then host._reader_link_confirm=nil end end,
                ok_callback=function()
                    if host._reader_link_confirm~=confirm then return end
                    close_view(host,'_reader_link_confirm')
                    if not owns(host,owner) then return end
                    if storage(host):remove(id) then M.list(host,page) else host:showInfo(_('Could not remove this imported entry.')) end
                end}
            host._reader_link_confirm=confirm;UIManager:show(confirm)
        end)},
        {text=_('Imported books'),callback=choose(function() M.list(host,page) end)},
    })
end
function M.list(host,page)
    host:closeWeReadUI()
    local owner=scope(host)
    if not owner.account then host:showInfo(_('Sign in to view this account\'s imported books.'));return end
    page=page or 0
    local result=storage(host):list(page*20,20)
    if not result then host:showInfo(_('Saved reader links could not be read. Check storage.'));return end
    local rows,widget={},nil
    local function choose(callback)
        return function()
            if host._reader_link_menu~=widget or not owns(host,owner) then return end
            close_view(host,'_reader_link_menu');callback()
        end
    end
    rows[#rows+1]={text=_('Import reader link'),callback=choose(function() M.input(host) end)}
    for _i,book in ipairs(result.books) do
        rows[#rows+1]={text=book.title,mandatory=book.author,callback=choose(function() M.actions(host,book.book_id,page) end)}
    end
    if #result.books==0 then rows[#rows+1]={text=_('No imported books on this page.'),select_enabled=false} end
    if page>0 then rows[#rows+1]={text=_('Previous batch'),callback=choose(function() M.list(host,page-1) end)} end
    if result.has_more then rows[#rows+1]={text=_('Next batch'),callback=choose(function() M.list(host,page+1) end)} end
    widget=menu(host,'_reader_link_menu',_('Imported books'),rows)
end
return M

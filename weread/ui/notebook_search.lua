-- Search account-local personal-note snapshots in a cancellable worker.
local Model=require('weread.lib.notebook_search')
local Marks=require('weread.lib.my_cloud_marks')
local Store=require('weread.lib.my_cloud_marks_store')
local Protocol=require('weread.lib.protocol')
local Query=require('weread.lib.search_query')
local Popup=require('weread.ui.shelf_popup')
local UI=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}
function M.cancel(host,owner)
    local job=owner.note_search_job;owner.note_search_job=nil
    if not job then return end
    if owner.note_search_worker then owner.note_search_worker:cancel() end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
local function valid_result(value,offset)
    local function count(v,max) return type(v)=='number' and v>=0 and v<=max and v%1==0 end
    if type(value)~='table' or type(value.items)~='table' or #value.items>Model.MAX_RESULTS
        or not count(value.available,Store.MAX_BOOKS*2) or not count(value.checked,value.available)
        or not count(value.failed,value.checked) or not count(value.not_cached,10000) or type(value.truncated)~='boolean' then return false end
    local cursor=value.next_cursor
    if value.truncated then
        if #value.items~=Model.MAX_RESULTS or type(cursor)~='table' or cursor.offset~=offset+Model.MAX_RESULTS
            or type(cursor.digest)~='string' or #cursor.digest~=64 or not cursor.digest:match('^[0-9a-f]+$') then return false end
    elseif cursor~=nil then return false end
    for key in pairs(value.items) do if not count(key,#value.items) or key<1 then return false end end
    for _,item in ipairs(value.items) do
        if type(item)~='table' or not Marks.display_id(item.book_id) or item.kind~='marks' and item.kind~='thoughts'
            or type(item.item_id)~='string' or #item.item_id<1 or #item.item_id>256 or item.item_id:find('%s')
            or type(item.preview)~='string' or #item.preview>1024 or item.preview:find('[%z%c]')
            or Protocol.utf8_substr(item.preview,#item.preview)~=item.preview then return false end
    end
    return true
end
local function show(host,owner,current,catalog,result,paging)
    if not current(host,owner) or owner.value~=catalog then return end
    local titles,labels={},{}
    for _,book in ipairs(catalog and catalog.books or {}) do titles[book.bookId]=book.title end
    local function title(id)
        if labels[id] then return labels[id] end
        local value=titles[id]
        if not value and type(host.settings.get_book)=='function' then
            local ok,book=pcall(host.settings.get_book,host.settings,id)
            if ok and type(book)=='table' and type(book.title)=='string' then value=book.title end
        end
        if type(value)~='string' or value=='' then value=T(_('Book %1'),id) end
        value=value:gsub('[%z%c]',' ')
        local short=Protocol.utf8_substr(value,36)
        labels[id]=#short<#value and short..'…' or short
        return labels[id]
    end
    local rows={{text=_('Only notes saved on this device are searched.'),select_enabled=false},
        {text=T(_('Searched %1 of %2 saved snapshots.'),result.checked,result.available),select_enabled=false}}
    if result.not_cached>0 or result.failed>0 then
        rows[#rows+1]={text=T(_('%1 notebook snapshots are not saved; %2 could not be read.'),result.not_cached,result.failed),select_enabled=false}
    end
    if paging.page>1 or result.truncated then
        rows[#rows+1]={text=T(_('Results batch %1'),paging.page),select_enabled=false}
    end
    if #result.items==0 then rows[#rows+1]={text=_('No matching saved notes.'),select_enabled=false} end
    local menu
    local function move(page,cursor)
        if not current(host,owner) or owner.value~=catalog or not Popup.current(owner.menu,menu) then return end
        Popup.close(owner.menu)
        paging.page=page;paging.cursors[page]=cursor
        M.start(host,owner,current,paging.query,paging)
    end
    if paging.page>1 then
        rows[#rows+1]={text=_('Previous results'),callback=function() move(paging.page-1,paging.cursors[paging.page-1]) end}
    end
    if result.truncated then
        rows[#rows+1]={text=_('More results'),callback=function() move(paging.page+1,result.next_cursor) end}
    end
    for _i,item in ipairs(result.items) do
        local record=item
        rows[#rows+1]={text=record.preview,saved_note_id=record.item_id,saved_book_id=record.book_id,
            mandatory=_(record.kind=='thoughts' and 'Thought' or 'Cloud mark')..' · '..title(record.book_id),callback=function()
            if not current(host,owner) or owner.value~=catalog or not Popup.current(owner.menu,menu) then return end
            Popup.close(owner.menu)
            if not current(host,owner) or owner.value~=catalog then return end
            local opened=require('weread.ui.my_cloud_marks').open_saved(host,record.book_id,record.kind,record.item_id)
            if not current(host,owner) then return end
            if opened then owner.child=host._my_marks_owner
            else host:showInfo(_('This saved note is no longer available. Search again.')) end
        end}
    end
    menu=host:showList(_('Saved note search results'),rows,nil,{thought_text=true})
    if not menu then return end
    Popup.show(owner.menu,menu,function() end)
end
function M.start(host,owner,current,query,paging)
    if not current(host,owner) or owner.context or owner.note_search_job then return false end
    local catalog=owner.value
    paging=paging or {query=query,page=1,cursors={}}
    local cursor=paging.cursors[paging.page]
    local job={};owner.note_search_job=job
    local function valid() return owner.note_search_job==job and current(host,owner) and owner.value==catalog end
    host:showBusy(_('Searching saved notes…\nTap or press a key to cancel.'),function() if owner.note_search_job==job then M.cancel(host,owner) end end)
    job.busy=host.busy_message
    local ok,worker=pcall(function()
        return owner.note_search_worker or require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=512*1024,timeout=600}
    end)
    if not ok or not worker then M.cancel(host,owner);host:showInfo(_('Could not search saved notes.'));return false end
    owner.note_search_worker=worker
    local started,active=pcall(worker.start,worker,function()
        return Store.with_read_snapshot(host.library_db,host.client,function(marks,thoughts)
            return Model.search(catalog and catalog.books or {},marks,thoughts,query,cursor)
        end)
    end,function(result)
        if not valid() then if owner.note_search_job==job then M.cancel(host,owner) end;return end
        M.cancel(host,owner)
        if type(result)=='table' and result.changed==true then
            host:showInfo(_('Saved notes changed. Search again to see current results.'));return
        end
        if not valid_result(result,cursor and cursor.offset or 0) then host:showInfo(_('Could not search saved notes.'));return end
        show(host,owner,current,catalog,result,paging)
    end)
    if not started or not active then M.cancel(host,owner);host:showInfo(_('Could not search saved notes.'));return false end
    return true
end
function M.prompt(host,owner,current)
    if not current(host,owner) then return false end
    if owner.context or owner.note_search_job then host:showInfo(_('Wait for the current operation to finish.'));return false end
    local dialog
    dialog=require('ui/widget/inputdialog'):new{title=_('Search all saved notes'),input='',input_type='text',buttons={{
        {text=_('Cancel'),callback=function() if Popup.current(owner.menu,dialog) then Popup.close(owner.menu) end end},
        {text=_('Search'),is_enter_default=true,callback=function()
            if not current(host,owner) or not Popup.current(owner.menu,dialog) then return end
            local query=Query.trim(dialog:getInputText())
            if query=='' then host:showInfo(_('Enter search text.'));return end
            if #query>1024 or Protocol.utf8_substr(query,#query)~=query then host:showInfo(_('Search text is too long or invalid.'));return end
            Popup.close(owner.menu);M.start(host,owner,current,query)
        end},
    }}}
    Popup.show(owner.menu,dialog,function(widget) host:showInputDialog(widget) end)
    return true
end
return M

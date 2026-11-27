local Data = require('weread.lib.discovery_data')
local ReadAccess = require('weread.lib.read_access')
local Search = require('weread.lib.shelf_search')
local Query = require('weread.lib.search_query')
local ShelfSnapshot = require('weread.lib.shelf_snapshot')
local Popup = require('weread.ui.shelf_popup')
local Scope = require('weread.ui.page_scope')
local Util = require('weread.lib.plugin_util')
local UI = require('ui/uimanager')
local _, T = Util.tr, Util.T
local M = {}

local function owned(record, account)
    return record and account and (record._library_account_key == account
        or record._library_account_key == nil and (record.home_recent_account or record.recent_read_account) == account)
end

local function collect(host, current)
    local account = host.library_db and host.library_db:accountKey()
    if not account then return {}, {} end
    local saved = host.settings:get('books', {})
    local shelf = host.library_db:getShelf() or {}
    local scope=host.settings.get_auth_scope and host.settings:get_auth_scope()
    local records={}
    if scope then
        local store=require('weread.lib.native_direct_batch_plan'):new(host.library_db,scope)
        records=store:list(current) or {}
    end
    local rows, seen, books = {}, {}, {}
    for _,record in ipairs(records) do books[record.book_id]=false end
    local function append(id, source)
        if not id or seen[id] then return end
        local row = Data.book(source)
        if not row then return end
        seen[id] = true
        local record, conflict = ReadAccess.cached_book(saved, id)
        if conflict then return end
        local downloaded = host:bookRecordHasDownload(record)
        local native_cached = not downloaded and host:nativeChapterCachePresent(id, current)
        if not (downloaded or native_cached or books[id]~=nil) then return end
        row.bookId = id
        if row.title == '' then row.title = id end
        if row.author == '' and type(source.authors)=='string' then row.author = source.authors end
        if books[id]~=nil then books[id]=row end
        if downloaded or native_cached then
            row._cached = true
            row._native_cached_hint = native_cached or nil
            rows[#rows + 1] = row
        end
    end
    for _, book in ipairs(shelf) do
        append(ReadAccess.display_book_id(ShelfSnapshot.persisted_id(book)), book)
    end
    for key in pairs(saved) do
        local id = ReadAccess.display_book_id(key)
        local record = id and ReadAccess.cached_book(saved, id)
        if owned(record, account) then append(id, record) end
    end
    local titles = {}
    for _, row in ipairs(rows) do titles[row] = Search.prepare(row.title) or row.bookId end
    table.sort(rows, function(a,b)
        if titles[a] == titles[b] then return a.bookId < b.bookId end
        return titles[a] < titles[b]
    end)
    local plans={}
    for _,record in ipairs(records) do
        local id=record.book_id
        local book=books[id]
        if not book and host.library_db.getBook then book=Data.book(host.library_db:getBook(id)) end
        if not book or book.bookId~=id or book.title=='' then book={bookId=id,title=T(_('Book ID: %1'),id)} end
        plans[#plans+1]={book=book,record=record}
    end
    return rows,plans
end

local function show_detail(host, book)
    local record, conflict = ReadAccess.load_cached_book(host.settings, book.bookId)
    local downloaded = not conflict and host:bookRecordHasDownload(record)
    local native_cached = not conflict and (book._native_cached_hint or host:nativeChapterCachePresent(book.bookId))
    if not (downloaded or native_cached) then
        host:showInfo(_('No cached file.'))
        return
    end
    local detail = {}
    if owned(record, host.library_db:accountKey()) then
        for key,value in pairs(record) do detail[key] = value end
    end
    for key,value in pairs(book) do if key~='_native_cached_hint' then detail[key] = value end end
    return host:showBookMenu(detail,{read_saved_native=not downloaded and native_cached})
end

local function show_actions(host, book, view, current)
    if view._shelf_popup then return end
    local dialog
    local function action(callback)
        return function()
            UI:nextTick(function()
                if not current() or not Popup.current(view, dialog) then return end
                Popup.close(view)
                if current() and callback then callback() end
            end)
        end
    end
    dialog = require('ui/widget/buttondialog'):new{
        title = book.title, buttons = {
            {{text = _('Read downloaded copy'), callback = action(function()
                host:readFromBookList(Data.book(book), view, current, true, book._native_cached_hint)
            end)}},
            {{text = _('Book details'), callback = action(function() show_detail(host, book) end)}},
            {{text = _('Cancel'), callback = action()}},
        },
    }
    Popup.show(view, dialog)
end

local function show_plan_actions(host, entry, view, menu, current)
    if menu._shelf_popup then return end
    local dialog
    local function action(options)
        return function()
            UI:nextTick(function()
                if not current() or not Popup.current(view,menu) or not Popup.current(menu,dialog) then return end
                if not options then Popup.close(menu);return end
                Popup.close(view)
                if not current() then return end
                local detail=host:showBookMenu(entry.book,{read_saved_native=options.cached==true})
                if detail then require('weread.ui.native_direct_reading').start(host,entry.book,detail,options) end
            end)
        end
    end
    dialog=require('ui/widget/buttondialog'):new{
        title=entry.book.title,buttons={
            {{text=_('Continue download'),callback=action({batch=true,resume_plan=entry.record})}},
            {{text=_('Saved E-Ink chapters'),callback=action({cached=true})}},
            {{text=_('Cancel'),callback=action()}},
        },
    }
    Popup.show(menu,dialog)
end

local function show_plans(host,plans)
    local view=host.shelf_view
    if not view or view._shelf_popup then return end
    local current=Scope.capture(host,view)
    local items,menu={}
    for index,entry in ipairs(plans) do
        local text=T(_('Chapters %1–%2'),entry.record.first,entry.record.last)
        items[index]={text=text..' · '..entry.book.title,index=index}
    end
    menu=host:showList(_('Unfinished downloads'),items,nil,{on_choice=function(item)
        if type(item)~='table' or not item.index or items[item.index]~=item or not current()
            or not Popup.current(view,menu) then return end
        show_plan_actions(host,plans[item.index],view,menu,current)
    end})
    if not menu then return end
    local closed=menu.onCloseWidget
    menu.onCloseWidget=function(widget,...)
        widget._shelf_closed=true
        Popup.close(widget)
        if closed then return closed(widget,...) end
    end
    Popup.show(view,menu,function() end)
end

local load
local function render(host, rows, plans, query, page)
    local needle = Search.prepare(query)
    local terms = Search.terms(needle)
    local books = {}
    for _, row in ipairs(rows) do
        if Search.matches(row, needle, terms) then books[#books+1] = row end
    end
    local function reload(next_page) load(host, query, next_page) end
    host:showDiscoveryPage('downloads', books, {
        title = query == '' and _('Downloaded books') or T(_('Downloaded books · %1'), query),
        page = page,
        actions = #plans>0 and {{text=T(_('Unfinished downloads · %1'),#plans),callback=function() show_plans(host,plans) end}} or nil,
        empty_text = query == '' and _('No downloaded books for this account.') or _('No matching books.'),
        on_refresh = reload,
        on_return = function(next_page)
            local current = Scope.capture(host, host.shelf_view)
            -- The detail close callback runs before KOReader removes its widget.
            UI:nextTick(function() if current() then reload(next_page) end end)
        end,
        on_search = function(view, current)
            local dialog
            local function submit(value)
                if not current() or not Popup.current(view, dialog) then return end
                local next_query = Query.trim(value)
                if #next_query > 1024 then host:showInfo(_('Search text is too long.')); return end
                Popup.close(view)
                if next_query ~= query then render(host, rows, plans, next_query, 1) end
            end
            dialog = require('ui/widget/inputdialog'):new{
                title = _('Search downloaded books'), input = query, input_type = 'text', buttons = {{
                    { text = _('Clear'), callback = function() submit('') end },
                    { text = _('Search'), is_enter_default = true, callback = function() submit(dialog:getInputText()) end },
                }},
            }
            Popup.show(view, dialog, function(widget) host:showInputDialog(widget) end)
        end,
        on_select = function(book) show_detail(host, book) end,
        on_hold = function(book, view, current)
            show_actions(host, book, view, current)
        end,
    })
end

function M.cancel(host)
    local job = host._download_library_job
    if not job then return end
    host._download_library_job = nil
    job.worker:cancel()
    if job.busy and host.busy_message == job.busy then host:closeBusy() end
end

load = function(host, query, page)
    M.cancel(host)
    local current = Scope.capture(host, host.shelf_view)
    local ok, worker = pcall(function()
        return require('weread.lib.memory_worker'):new{ scheduler=UI, codec=host.client, max_bytes=4*1024*1024 }
    end)
    local message = _('Could not load downloaded books.')
    if not ok then host:showInfo(message); return end
    local job = { worker=worker }
    host._download_library_job = job
    host:showBusy(_('Loading downloaded books…'), function() M.cancel(host) end)
    job.busy = host.busy_message
    local started = worker:start(function()
        local rows,plans=collect(host,current)
        return {rows=rows,plans=plans}
    end, function(result)
        if host._download_library_job ~= job then return end
        local live = not host._weread_suspended and current()
        M.cancel(host)
        if not live then return end
        if not result or type(result.rows)~='table' or type(result.plans)~='table' then host:showInfo(message); return end
        render(host, result.rows, result.plans, query, page)
    end)
    if not started then M.cancel(host); host:showInfo(message) end
end

function M.show(host)
    host:closeWeReadUI()
    load(host, '', 1)
end

return M

-- Link lookup uses the native worker; local imports remain account scoped.
local Model=require('weread.lib.mp_link')
local Store=require('weread.lib.mp_link_store')
local Popup=require('weread.ui.shelf_popup')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
function M.cancel(host)
    local job=host.mp_link_job;host.mp_link_job=nil
    if job and host.mp_link_worker then host.mp_link_worker:cancel() end
    if job and host.busy_message==job.busy then host:closeBusy() end
    local menu=host._mp_link_menu;host._mp_link_menu=nil
    if menu then UI:close(menu) end
end
local function text_error(host)
    host:showInfo(_('Could not import this article. Check the link, E-Ink login, network and storage, then try again.'))
end
function M.list(host,owner,current)
    if not current() then return end
    local account=host.library_db and host.library_db:accountKey()
    local rows=Store.list(host.library_db,account)
    if not rows then text_error(host);return end
    if #rows==0 then host:showInfo(_('No imported articles.'));return end
    local items,menu={}
    for index,row in ipairs(rows) do
        local book={book_id=row.book_id,title=_('Public Account')}
        local article={reviewId=row.review_id,bookId=row.book_id,title=row.title~='' and row.title or _('Article')..' '..tostring(#rows-index+1)}
        local cached=host:getCachedMPArticles(row.book_id)
        if type(cached)=='table' then
            for _,item in ipairs(cached) do
                if type(item)=='table' and item.reviewId==row.review_id and type(item.title)=='string' and item.title~='' then
                    article.title=item.title;break
                end
            end
        end
        local saved=host.settings:get('books',{})[row.book_id]
        if type(saved)=='table' and type(saved.title)=='string' and saved.title~='' then book.title=saved.title end
        items[#items+1]={text=article.title,post_text=book.title,callback=function()
            if not current() or host._mp_link_menu~=menu or host.library_db:accountKey()~=account then return end
            local path=require('weread.lib.content').mp_article_cached_path(host.settings,book,article)
            if path then require('weread.ui.mp_record_recovery').open(host,book,article,path)
            else host:downloadMPArticleAndRead(book,article) end
        end}
    end
    if host._mp_link_menu then UI:close(host._mp_link_menu) end
    menu=host:showList(_('Imported articles'),items,_('No imported articles.'))
    host._mp_link_menu=menu
    if menu then
        local previous=menu.onCloseWidget
        menu.onCloseWidget=function(instance,...)
            if host._mp_link_menu==instance then host._mp_link_menu=nil end
            if previous then return previous(instance,...) end
        end
    end
end
function M.start(host,owner,current,url)
    if not current() then return false end
    M.cancel(host)
    if not host:isNetworkConnected() then host:showOffline(_('Import article link'));return false end
    local account=host.library_db and host.library_db:accountKey()
    local ok,input=pcall(Model.capture,host.settings,url)
    if not account or not ok or not input then text_error(host);return false end
    local job={account=account,input=input,started=os.time()};host.mp_link_job=job
    local function active()
        local age=os.time()-job.started
        return host.mp_link_job==job and current() and host.library_db:accountKey()==account
            and age>=0 and age<=120 and Model.matches(host.settings,input)
    end
    host:showBusy(_('Resolving article link…\nTap or press a key to cancel.'),function()
        if host.mp_link_job==job then M.cancel(host) end
    end)
    job.busy=host.busy_message
    if not host.mp_link_worker then
        local made,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=Model.MAX_RESULT} end)
        if not made then M.cancel(host);text_error(host);return false end
        host.mp_link_worker=worker
    end
    local started,accepted=pcall(host.mp_link_worker.start,host.mp_link_worker,
        function() return Model.read(host.client,host.settings,input) end,function(result)
            if not active() then if host.mp_link_job==job then M.cancel(host) end;return end
            M.cancel(host)
            if type(result)~='table' or result.ok~=true or not Store.identity(result.book_id,result.review_id) or not Model.title(result.title) then
                text_error(host);return
            end
            if not Store.add(host.library_db,account,result.book_id,result.review_id,result.title) then text_error(host);return end
            M.list(host,owner,current)
        end)
    if not started or not accepted then M.cancel(host);text_error(host);return false end
    return true
end
function M.dialog(host,owner,current)
    if not current() then return end
    local dialog
    dialog=require('ui/widget/inputdialog'):new{
        title=_('Import article link'),input='',input_type='text',buttons={{
            {text=_('Cancel'),callback=function() if Popup.current(owner,dialog) then Popup.close(owner) end end},
            {text=_('Import'),is_enter_default=true,callback=function()
                if not current() or not Popup.current(owner,dialog) then return end
                local value=dialog:getInputText();Popup.close(owner);M.start(host,owner,current,value)
            end},
        }},
    }
    Popup.show(owner,dialog,function(widget) host:showInputDialog(widget) end)
end
return M

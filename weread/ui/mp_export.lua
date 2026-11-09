-- Native MP export picker and cancellable local worker. No network dependency.
local Model=require('weread.lib.mp_export')
local Content=require('weread.lib.content')
local Output=require('weread.lib.notes_export_file')
local Protocol=require('weread.lib.protocol')
local CacheIdentity=require('weread.lib.mp_cache_identity')
local UIManager=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}
local function scope(host)
    return {account=host.library_db and host.library_db:accountKey(),epoch=host.discovery_epoch or 0,
        document=host.ui and host.ui.document,file=host.ui and host.ui.document and host.ui.document.file,
        session=host._reader_session_gen}
end
local function current(host,owner)
    return owner.account==(host.library_db and host.library_db:accountKey()) and owner.epoch==(host.discovery_epoch or 0)
        and owner.document==(host.ui and host.ui.document) and owner.file==(host.ui and host.ui.document and host.ui.document.file)
        and owner.session==host._reader_session_gen
end
local function close(host,key)
    local widget=host[key];host[key]=nil;if widget then UIManager:close(widget) end
end
local function own_widget(host,key,widget)
    host[key]=widget
    if not widget then return end
    local on_close=widget.onCloseWidget
    widget.onCloseWidget=function(instance,...)
        if host[key]==instance then host[key]=nil end
        if on_close then return on_close(instance,...) end
    end
end
function M.cancel(host)
    for _i,key in ipairs({'_mp_export_picker','_mp_export_menu','_mp_export_result'}) do close(host,key) end
    local job=host.mp_export_job;host.mp_export_job=nil
    if not job then return end
    if host.mp_export_worker then host.mp_export_worker:cancel() end
    if job.output then job.output:abort();job.output=nil end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
local function input(host,book,article)
    if type(book)~='table' or type(article)~='table' or not Protocol.is_mp_book(book.book_id or book.bookId) then return nil end
    local ok,path,reason=pcall(Content.mp_article_cached_path,host.settings,book,article)
    if ok and reason=='ambiguous_legacy' then return nil,reason end
    if not ok or type(path)~='string' or #path>4096 or path:find('[%z%c]')
        or not path:match('%.html$') and not path:match('%.epub$') or Model.is_export_path(host.settings,path) then return nil end
    local identity=require('libs/libkoreader-lfs').symlinkattributes(path)
    if not identity or identity.mode~='file' then return nil end
    return {path=path,identity=identity,cache_kind=reason,
        book={book_id=book.book_id or book.bookId,title=book.title,author=book.author},
        article={title=article.title,reviewId=article.reviewId,originalId=article.originalId,bookId=article.bookId}}
end
local function failed(host) host:showInfo(_('Could not export this article. Check its cache and available storage.')) end
local function success(host,owner,output,result)
    local path=output.path
    local dialog
    dialog=require('ui/widget/confirmbox'):new{keep_dialog_open=true,
        text=result.copied and T(_('Exported the saved EPUB to:\n%1'),path)
            or T(_('Article exported to:\n%1\n\nIncluded images: %2\nImages unavailable: %3'),path,result.images,result.missing),
        ok_text=_('Open exported article'),cancel_text=_('Close'),
        cancel_callback=function() if host._mp_export_result==dialog then host._mp_export_result=nil end end,
        ok_callback=function()
            if host._mp_export_result~=dialog then return end
            close(host,'_mp_export_result')
            if not current(host,owner) then return end
            if output:owns() and require('libs/libkoreader-lfs').attributes(path,'size')==result.bytes then
                host:openFile(path)
            else failed(host) end
        end}
    own_widget(host,'_mp_export_result',dialog);UIManager:show(dialog)
end
function M.start(host,book,article,prepared)
    M.cancel(host)
    local owner=scope(host)
    local valid,source=pcall(function() return prepared or input(host,book,article) end)
    local directory=Model.directory(host.settings)
    if not valid or not source or not directory then failed(host);return false end
    local created,output=pcall(host.create_mp_output or Output.create,directory,source.article.title or _('Article'),'epub')
    if not created or not output then failed(host);return false end
    local job={owner=owner,output=output,started=os.time()};host.mp_export_job=job
    host:showBusy(_('Exporting article…\nTap or press a key to cancel.'),function() if host.mp_export_job==job then M.cancel(host) end end)
    job.busy=host.busy_message
    local function stop() M.cancel(host);failed(host) end
    if not host.mp_export_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client} end)
        if not ok then stop();return false end;host.mp_export_worker=worker
    end
    local labels={missing=_('Image unavailable')}
    local ok,started=pcall(host.mp_export_worker.start,host.mp_export_worker,function()
        local good,result=pcall(Model.write,source,output,labels)
        return good and result or {ok=false}
    end,function(result)
        if host.mp_export_job~=job then return end
        local age=os.time()-job.started
        if not current(host,owner) or age<0 or age>120 then M.cancel(host);return end
        if type(result)~='table' or result.ok~=true or type(result.copied)~='boolean'
            or type(result.bytes)~='number' or result.bytes%1~=0 or result.bytes<1 or result.bytes>Model.MAX_OUTPUT
            or type(result.images)~='number' or result.images%1~=0 or result.images<0 or result.images>Model.MAX_ASSETS
            or type(result.missing)~='number' or result.missing%1~=0 or result.missing<0 or result.missing>Model.MAX_NODES then stop();return end
        local accepted,complete=pcall(output.accept,output,result.bytes)
        if not accepted or not complete then stop();return end
        job.output=nil;M.cancel(host);success(host,owner,output,result)
    end)
    if not ok or not started then stop();return false end
    return true
end
function M.show(host,book,article,prepared)
    host:closeWeReadUI()
    local owner=scope(host)
    local ok,source=pcall(function() return prepared or input(host,book,article) end)
    local directory=Model.directory(host.settings)
    if not ok or not source or not directory then failed(host);return false end
    local picker
    picker=require('ui/widget/confirmbox'):new{keep_dialog_open=true,
        text=T(_('Export this cached article as an EPUB?\n\n%1\n\nAvailable saved images are included. Other images get a placeholder.\n\nSave to:\n%2'),source.article.title or _('Article'),directory),
        ok_text=_('Export EPUB'),cancel_text=_('Cancel'),
        cancel_callback=function() if host._mp_export_picker==picker then host._mp_export_picker=nil end end,
        ok_callback=function()
            if host._mp_export_picker~=picker then return end
            close(host,'_mp_export_picker')
            if current(host,owner) then M.start(host,nil,nil,source) end
        end}
    own_widget(host,'_mp_export_picker',picker);UIManager:show(picker);return true
end
function M.list(host,book,articles)
    host:closeWeReadUI()
    local owner=scope(host)
    local rows,menu,candidates,counts,seen={},nil,{},{},{}
    for index,article in ipairs(articles or {}) do
        if index>1000 then break end
        local ok,source,reason=pcall(input,host,book,article)
        if ok and source then
            local key=CacheIdentity.key(book,article)
            local identity=key and source.path..'\0'..key
            if not identity or not seen[identity] then
                candidates[#candidates+1]=source;counts[source.path]=(counts[source.path] or 0)+1
                if identity then seen[identity]=true end
            end
        elseif ok and reason=='ambiguous_legacy' then
            rows[#rows+1]={text=article.title or _('Article'),mandatory=_('Legacy cache needs refresh'),select_enabled=false}
        end
    end
    for _i,source in ipairs(candidates) do
        local ambiguous=counts[source.path]>1
        rows[#rows+1]={text=source.article.title or _('Article'),
            mandatory=ambiguous and _('Ambiguous cache') or source.cache_kind=='legacy' and _('Legacy cache') or '',select_enabled=not ambiguous,callback=function()
                if ambiguous then return end
                if host._mp_export_menu~=menu or not current(host,owner) then return end
                M.show(host,nil,nil,source)
            end}
    end
    if #rows==0 then host:showInfo(_('No cached articles to export.'));return end
    menu=host:showList(_('Export cached article'),rows);own_widget(host,'_mp_export_menu',menu)
end
function M.current(host)
    local id=host:detectWeReadBook()
    local path=host.ui and host.ui.document and host.ui.document.file
    local book=id and host.settings:get('books',{})[id]
    local selected,ambiguous
    if Protocol.is_mp_book(id) and type(book)=='table' and type(path)=='string' then
        for index,article in ipairs(book.mp_articles or {}) do
            if index>1000 then break end
            local cached,reason=Content.mp_article_cached_path(host.settings,book,article)
            if cached==path then
                if selected and (not CacheIdentity.key(book,selected) or CacheIdentity.key(book,selected)~=CacheIdentity.key(book,article)) then
                    failed(host);return false
                end
                selected=article
            elseif reason=='ambiguous_legacy' and Content.mp_article_legacy_path(host.settings,book,article)==path then
                ambiguous=true
            end
        end
    end
    if not selected then host:showInfo(ambiguous and _('This old article cache is ambiguous. Download the article again from the article list.')
        or _('This article could not be identified in the saved article list.'));return false end
    return M.show(host,book,selected)
end
return M

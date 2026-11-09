-- Cache management remains usable offline; refresh delegates to the existing worker.
local Content=require('weread.lib.content')
local Identity=require('weread.lib.mp_cache_identity')
local Versions=require('weread.lib.mp_cache_versions')
local UIManager=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}
local function close(host,key)
    local widget=host[key];host[key]=nil;if widget then UIManager:close(widget) end
end
local function own(host,key,widget)
    host[key]=widget
    if widget then
        local on_close=widget.onCloseWidget
        widget.onCloseWidget=function(instance,...)
            if host[key]==instance then host[key]=nil end
            if on_close then return on_close(instance,...) end
        end
    end
end
function M.cancel(host)
    for _i,key in ipairs({'_mp_refresh_confirmation','_mp_versions_menu','_mp_actions_menu','_mp_cache_picker'}) do close(host,key) end
end
local function scope(host,book)
    local record=host.settings:get('books',{})[book.book_id or book.bookId]
    return {account=host.library_db and host.library_db:accountKey() or false,epoch=host.discovery_epoch or 0,
        document=host.ui and host.ui.document or false,file=host.ui and host.ui.document and host.ui.document.file or false,
        session=host._reader_session_gen or false,cache=host.settings.cache_dir or false,record=record and record.cache_dir or false,
        root=Content.book_resolved_dir(host.settings,book.book_id or book.bookId,book)}
end
local function current(host,owner,book)
    local now=scope(host,book)
    for key,value in pairs(owner) do if now[key]~=value then return false end end
    return true
end
local function source(host,book,article)
    local key=Identity.key(book,article);if not key then return nil end
    local path,kind=Content.mp_article_cached_path(host.settings,book,article)
    local info=path and require('libs/libkoreader-lfs').symlinkattributes(path)
    if not info or info.mode~='file' then return nil end
    return {path=path,info=info,key=key,kind=kind}
end
local function unchanged(host,book,article,saved)
    local ok,now=pcall(source,host,book,article)
    return ok and now and now.path==saved.path and now.key==saved.key and Versions.same(now.info,saved.info)
end
local function failed(host) host:showInfo(_('The saved article changed or is unavailable. Reopen its article list and try again.')) end
function M.refresh(host,book,article)
    local ok,saved=pcall(source,host,book,article)
    if not ok or not saved then failed(host);return false end
    local owner=scope(host,book)
    local dialog
    dialog=require('ui/widget/confirmbox'):new{keep_dialog_open=true,
        text=T(_('Download a new version of this article?\n\n%1\n\nThe previous version, its reading position and notes are kept in Saved versions. No position or notes are copied into the new version.'),article.title or _('Article')),
        ok_text=_('Refresh article'),cancel_text=_('Cancel'),
        cancel_callback=function() if host._mp_refresh_confirmation==dialog then host._mp_refresh_confirmation=nil end end,
        ok_callback=function()
            if host._mp_refresh_confirmation~=dialog then return end
            close(host,'_mp_refresh_confirmation')
            if not current(host,owner,book) then return end
            if not unchanged(host,book,article,saved) then failed(host);return end
            require('weread.ui.mp_download').start(host,book,article,{preserve=true})
        end}
    close(host,'_mp_refresh_confirmation');own(host,'_mp_refresh_confirmation',dialog);UIManager:show(dialog);return true
end
function M.history(host,book,article)
    local ok,saved=pcall(source,host,book,article)
    if not ok or not saved then failed(host);return false end
    local owner=scope(host,book)
    local listed,entries=pcall(Versions.list,owner.root,saved.key)
    -- A legacy title cache may be the only saved version, or coexist with new ones.
    if not listed or not entries then
        if saved.kind=='legacy' then entries={} else failed(host);return false end
    end
    local legacy=Content.mp_article_legacy_path(host.settings,book,article)
    local catalog=book.mp_articles or (host.settings:get('books',{})[book.book_id or book.bookId] or {}).mp_articles
    local permitted=Identity.legacy_allowed(book,article,catalog,function(row)
        return Content.mp_article_legacy_path(host.settings,book,row)
    end)
    if permitted then
        for _i,path in ipairs({legacy,(legacy:gsub('%.html$','.epub'))}) do
            local info=require('libs/libkoreader-lfs').symlinkattributes(path)
            if info and info.mode=='file' then entries[#entries+1]={path=path,info=info,current=path==saved.path,legacy=true} end
        end
    end
    local rows,menu={}
    for index,entry in ipairs(entries) do
        rows[#rows+1]={text=T(_('Version %1 · %2'),index,os.date('%Y-%m-%d %H:%M',entry.info.modification)),
            mandatory=entry.current and _('Current cache') or entry.legacy and _('Legacy cache') or _('Previous cache'),callback=function()
                if host._mp_versions_menu~=menu or not current(host,owner,book) then return end
                local info=require('libs/libkoreader-lfs').symlinkattributes(entry.path)
                if Versions.same(info,entry.info) and (entry.legacy or Versions.contains(owner.root,saved.key,entry.path)) then host:openFile(entry.path) else failed(host) end
            end}
    end
    if #rows==0 then failed(host);return false end
    close(host,'_mp_versions_menu');menu=host:showList(_('Saved versions'),rows);own(host,'_mp_versions_menu',menu);return true
end
function M.show(host,book,article)
    local ok,saved=pcall(source,host,book,article)
    if not ok or not saved then failed(host);return false end
    local owner=scope(host,book);local menu
    local function action(fn)
        return function()
            if host._mp_actions_menu~=menu or not current(host,owner,book) then return end
            if not unchanged(host,book,article,saved) then failed(host);return end
            fn()
        end
    end
    local rows={
        {text=_('Read cached article'),callback=action(function() host:openFile(saved.path) end)},
        {text=_('Refresh article'),callback=action(function() M.refresh(host,book,article) end)},
        {text=_('Saved versions'),callback=action(function() M.history(host,book,article) end)},
        {text=_('Export cached article'),callback=action(function() host:showMPArticleExport(book,article) end)},
    }
    close(host,'_mp_actions_menu');menu=host:showList(article.title or _('Article'),rows);own(host,'_mp_actions_menu',menu);return true
end
function M.list(host,book,articles)
    host:closeWeReadUI()
    local owner=scope(host,book);local rows,seen,menu={},{},nil
    for index,article in ipairs(articles or {}) do
        if index>1000 then break end
        local ok,saved=pcall(source,host,book,article)
        if ok and saved and not seen[saved.key] then
            seen[saved.key]=true
            rows[#rows+1]={text=article.title or _('Article'),mandatory=saved.kind=='legacy' and _('Legacy cache') or '',callback=function()
                if host._mp_cache_picker==menu and current(host,owner,book) then M.show(host,book,article) end
            end}
        end
    end
    if #rows==0 then host:showInfo(_('No cached articles.'));return false end
    menu=host:showList(_('Article cache and versions'),rows);own(host,'_mp_cache_picker',menu);return true
end
return M

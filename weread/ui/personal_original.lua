-- Explicitly associate a local PDF with a chosen book, without cloud sync.
local Model=require('weread.lib.personal_upload')
local Original=require('weread.lib.personal_original')
local UI=require('ui/uimanager')
local Confirm=require('ui/widget/confirmbox')
local _=require('weread.lib.plugin_util').tr
local T=require('ffi/util').template
local M={}
local function current(host,ctx)
    return host._personal_original_attach==ctx and host._book_detail_view==ctx.view
        and host.library_db and host.library_db:accountKey()==ctx.account
        and host._reader_session_gen==ctx.session and (host.discovery_epoch or 0)==ctx.epoch
        and (host.ui and host.ui.document)==ctx.document
        and (host.ui and host.ui.document and host.ui.document.file)==ctx.file
end
function M.cancel(host)
    local ctx=host._personal_original_attach;host._personal_original_attach=nil
    if not ctx then return end
    if ctx.dialog then UI:close(ctx.dialog);ctx.dialog=nil end
    if ctx.chooser then UI:close(ctx.chooser);ctx.chooser=nil end
end
function M.forget(host,book,view,expected)
    M.cancel(host)
    local id=book and (book.book_id or book.bookId)
    local account=host.library_db and host.library_db:accountKey()
    if type(id)~='string' or not account or type(expected)~='table' or host._book_detail_view~=view then return false end
    local ctx={account=account,session=host._reader_session_gen,epoch=host.discovery_epoch or 0,
        document=host.ui and host.ui.document,file=host.ui and host.ui.document and host.ui.document.file,view=view}
    host._personal_original_attach=ctx
    local dialog
    dialog=Confirm:new{text=_('Remove this book’s local PDF association? The original file and cloud book are kept.'),
        ok_text=_('Remove association'),cancel_callback=function() if current(host,ctx) then M.cancel(host) end end,
        ok_callback=function()
            if not current(host,ctx) or ctx.dialog~=dialog then return end
            local ok,removed=pcall(Original.forget,host,id,expected)
            M.cancel(host)
            if ok and removed then
                UI:close(view);if host._book_detail_view==view then host._book_detail_view=nil end
                host:showBookMenu(book);host:showInfo(_('Local PDF association removed. The original file is kept.'))
            else host:showInfo(_('The local PDF association changed or could not be removed.')) end
        end}
    ctx.dialog=dialog;UI:show(dialog);return true
end
function M.start(host,book,view)
    M.cancel(host)
    local id=book and (book.book_id or book.bookId)
    local account=host.library_db and host.library_db:accountKey()
    if type(id)~='string' or not id:match('^CB_[A-Za-z0-9]+$') or not account
        or host._book_detail_view~=view then return false end
    local ctx={account=account,session=host._reader_session_gen,epoch=host.discovery_epoch or 0,
        document=host.ui and host.ui.document,file=host.ui and host.ui.document and host.ui.document.file,view=view};host._personal_original_attach=ctx
    local root=host.ui and host.ui.file_chooser and host.ui.file_chooser.path
        or G_reader_settings and G_reader_settings:readSetting('home_dir') or '/'
    local chooser
    chooser=require('ui/widget/pathchooser'):new{path=root,select_directory=false,select_file=true,
        file_filter=function(name) return Model.accepts_name(name) and name:lower():match('%.pdf$')~=nil end,
        title=_('Choose a local PDF'),onConfirm=function(path)
            if not current(host,ctx) or ctx.chooser~=chooser then return end
            ctx.chooser=nil
            UI:nextTick(function()
                if not current(host,ctx) then return end
                local ok,input=pcall(Model.capture,path)
                if not ok or not input or not input.name:lower():match('%.pdf$') then
                    M.cancel(host);host:showInfo(_('Could not use this local PDF.'));return
                end
                local dialog
                dialog=Confirm:new{text=T(_('Use “%1” as the local PDF for this book?\n\nThe plugin cannot verify that its contents match. Local reading does not sync to WeRead.'),input.name),
                    ok_text=_('Use local PDF'),cancel_callback=function() if current(host,ctx) then M.cancel(host) end end,
                    ok_callback=function()
                        if not current(host,ctx) or ctx.dialog~=dialog then return end
                        local saved,linked=pcall(Original.remember,host,id,input)
                        M.cancel(host)
                        if saved and linked then
                            UI:close(view);if host._book_detail_view==view then host._book_detail_view=nil end
                            host:showBookMenu(book);host:showInfo(_('Local PDF linked. Its reading position will not sync to WeRead.'))
                        else host:showInfo(_('Could not link this local PDF.')) end
                    end}
                ctx.dialog=dialog;UI:show(dialog)
            end)
        end}
    local close=chooser.onCloseWidget
    chooser.onCloseWidget=function(instance,...)
        if current(host,ctx) and ctx.chooser==instance then ctx.chooser=nil;M.cancel(host) end
        if close then return close(instance,...) end
    end
    ctx.chooser=chooser;UI:show(chooser);return true
end
return M

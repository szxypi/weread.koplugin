-- Local-only reader selection action. The captured text never enters sync.
local UI=require('ui/uimanager')
local Context=require('weread.lib.excerpt_context')
local _=require('weread.lib.plugin_util').tr
local M={KEY='weread_excerpt_card'}

local function account(host)
    return host.library_db and host.library_db:accountKey()
end
local function current(host,owner)
    return host.ui and host.ui.document==owner.document and owner.document and owner.document.file==owner.file
        and host._reader_session_gen==owner.session and account(host)==owner.account
        and host._excerpt_card_epoch==owner.epoch
end
function M.cancel(host)
    host._excerpt_card_epoch=(host._excerpt_card_epoch or 0)+1
    local editor=package.loaded['weread.ui.excerpt_card']
    if editor then editor.close(host) end
end
function M.view_changed(host) M.cancel(host) end
function M.detach(host)
    M.cancel(host)
    local hook=host._excerpt_card_hook;host._excerpt_card_hook=nil
    if hook and hook.target._highlight_buttons and hook.target._highlight_buttons[M.KEY]==hook.factory then
        hook.target:removeFromHighlightDialog(M.KEY)
    end
end
function M.attach(host)
    M.detach(host)
    local highlight=host.ui and host.ui.highlight
    if not highlight or type(highlight.addToHighlightDialog)~='function' or type(highlight.removeFromHighlightDialog)~='function' then return false end
    local function factory(this)
        return {id='weread_excerpt_card',text=_('Excerpt card'),show_in_highlight_dialog_func=function()
            return this.selected_text and type(this.selected_text.text)=='string' and #this.selected_text.text>0
                and this.select_mode~=true and host._current_weread_book_id~=nil
        end,callback=function()
            local hook=host._excerpt_card_hook
            if not hook or hook.factory~=factory or hook.target~=this or not host.ui or not host.ui.document then return end
            local selected=this.selected_text
            if not selected or type(selected.text)~='string' then return end
            local captured=Context.make(host,host._current_weread_book_id,selected.text,host.ui.doc_props)
            if not captured then host:showInfo(_('Select valid text of at most 4096 bytes for an excerpt card.'));return end
            local document=host.ui.document
            local owner={document=document,file=document.file,session=host._reader_session_gen,
                account=account(host),epoch=host._excerpt_card_epoch}
            owner.is_current=function() return current(host,owner) end
            this:onClose()
            if this.selected_text==selected then this.selected_text=nil end
            UI:scheduleIn(.1,function()
                if not current(host,owner) then return end
                local ok,shown=pcall(require('weread.ui.excerpt_card').show,host,captured,owner)
                if not ok or not shown then host:showInfo(_('Could not open the excerpt card.')) end
            end)
        end}
    end
    highlight:addToHighlightDialog(M.KEY,factory)
    host._excerpt_card_hook={target=highlight,factory=factory}
    return true
end
return M

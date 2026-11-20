-- Local-only reader selection action. The captured text never enters sync.
local UI=require('ui/uimanager')
local Query=require('weread.lib.search_query')
local Protocol=require('weread.lib.protocol')
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
local function safe_text(value,limit)
    if type(value)~='string' or #value>limit or value:find('[%z\1-\8\11\12\14-\31\127]')
        or Protocol.utf8_substr(value,#value+1)~=value then return '' end
    return Query.trim(value)
end
local function context(host,selection)
    local props=host.ui.doc_props or {}
    local books=host.settings:get('books',{})
    local book=type(books)=='table' and books[host._current_weread_book_id] or nil
    book=type(book)=='table' and book or {}
    local title=safe_text(book.title,1024)
    if title=='' then title=safe_text(props.title,1024) end
    if title=='' then title=_('Untitled book') end
    local author=safe_text(book.author or book.authors,1024)
    if author=='' then author=safe_text(props.authors or props.author,1024) end
    return {text=selection,book_title=title,book_author=author}
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
            local text=safe_text(selected.text,4096)
            if text=='' then host:showInfo(_('Select valid text of at most 4096 bytes for an excerpt card.'));return end
            local document=host.ui.document
            local owner={document=document,file=document.file,session=host._reader_session_gen,
                account=account(host),epoch=host._excerpt_card_epoch}
            local captured=context(host,text)
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

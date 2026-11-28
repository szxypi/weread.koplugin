-- Use already-saved notes only; no network requests or note modifications.
local Popup=require('weread.ui.shelf_popup')
local Context=require('weread.lib.excerpt_context')
local Identity=require('weread.lib.shelf_snapshot')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}

local function notebook_book(host,owner)
    local notebook=host._notebook_owner
    if not notebook or type(notebook.menu)~='table' or notebook.child~=owner or host._notebook_menu~=notebook.menu
        or notebook.menu._shelf_closed or notebook.account~=owner.account or notebook.epoch~=(host.discovery_epoch or 0)
        or notebook.session~=host._reader_session_gen or notebook.document~=(host.ui and host.ui.document)
        or not host.settings:auth_scope_matches(notebook.scope) or type(notebook.value)~='table'
        or type(notebook.value.books)~='table' then return nil end
    local found
    for _,book in ipairs(notebook.value.books) do
        if Identity.persisted_id(book)==owner.id then
            if found then return nil end
            found=book
        end
    end
    return found
end

function M.text(owner,row)
    if owner.thoughts then
        if type(row.abstract)=='string' and row.abstract~='' then return row.abstract end
        if type(row.content)=='string' and row.content~='' then return row.content end
    elseif row.type==1 then
        if type(row.markText)=='string' and row.markText~='' then return row.markText end
        if type(row.abstract)=='string' and row.abstract~='' then return row.abstract end
    end
end

function M.open(host,owner,row,viewer,current,generation)
    if not current(host,owner) or owner.generation~=generation or not Popup.current(owner.menu,viewer) then return false end
    local snapshot=owner.value
    local book=owner.parent and owner.parent._excerpt_book
    if Identity.persisted_id(book)~=owner.id then book=nil end
    book=book or notebook_book(host,owner)
    local context=Context.make(host,owner.id,M.text(owner,row),book)
    if not context then host:showInfo(_('Select valid text of at most 4096 bytes for an excerpt card.'));return false end
    if not current(host,owner) or owner.generation~=generation or owner.value~=snapshot
        or not Popup.current(owner.menu,viewer) then return false end
    local card_owner={parent=owner}
    card_owner.is_current=function()
        return current(host,owner) and owner.generation==generation and owner.value==snapshot
    end
    card_owner.is_visible=function(editor) return Popup.current(owner.menu,editor) end
    card_owner.show=function(editor) Popup.show(owner.menu,editor) end
    Popup.close(owner.menu)
    UI:nextTick(function()
        if not card_owner.is_current() or owner.menu._shelf_popup then return end
        local ok,shown=pcall(require('weread.ui.excerpt_card').show,host,context,card_owner)
        if (not ok or not shown) and card_owner.is_current() then host:showInfo(_('Could not open the excerpt card.')) end
    end)
    return true
end
return M

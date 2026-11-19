-- Actions stay tied to the page, account and book that opened the menu.
local ButtonDialog=require('ui/widget/buttondialog')
local UI=require('ui/uimanager')
local Popup=require('weread.ui.shelf_popup')
local Protocol=require('weread.lib.protocol')
local _=require('weread.lib.plugin_util').tr
local M={}

function M.open(host,owner,book,current)
    if not current() or owner._shelf_popup or type(book)~='table' then return false end
    local raw=book.book_id or book.bookId
    if (type(raw)~='string' and type(raw)~='number') or Protocol.is_mp_book(raw) then return false end
    local id=tostring(raw)
    if id=='' or #id>256 or id:find('[%z%c]') then return false end
    local library=host.library_db
    local account=library and library.accountKey and library:accountKey()
    local membership=account and host.shelf_membership
        and require('weread.lib.shelf_membership_write').book_id(id)
    local finished
    if account and host.client and library.open and library.getShelfStatus
        and #id<=20 and id:match('^[1-9]%d*$') then
        local ok,state=pcall(library.getShelfStatus,library,id)
        finished=ok and type(state)=='table' and state.present==true
    end
    if not current() then return false end
    local dialog
    local function action(callback)
        return function()
            UI:nextTick(function()
                if not current() or not Popup.current(owner,dialog) then return end
                Popup.close(owner)
                if current() and tostring(book.book_id or book.bookId or '')==id then callback() end
            end)
        end
    end
    local buttons={
        {{text=_('Read now'),callback=action(function()
            host:startBookReading(book,nil,{current=current})
        end)}},
        {{text=_('Book details'),callback=action(function() host:showBookRecord(book) end)}},
    }
    local function change(module)
        if not host:showShelfState(id) then return end
        local menu=host._shelf_state_menu
        if current() and menu and Popup.current(owner,menu) then require(module).open(host,id) end
    end
    if membership then buttons[#buttons+1]={{text=_('Change cloud membership'),callback=action(function()
        change('weread.ui.shelf_membership_write')
    end)}} end
    if finished then buttons[#buttons+1]={{text=_('Change finished mark'),callback=action(function()
        change('weread.ui.finish_change')
    end)}} end
    buttons[#buttons+1]={{text=_('Shelf status'),callback=action(function() host:showShelfState(id) end)}}
    buttons[#buttons+1]={{text=_('Cancel'),callback=action(function() end)}}
    dialog=ButtonDialog:new{title=book.title or _('Book details'),buttons=buttons}
    Popup.show(owner,dialog)
    return true
end
return M

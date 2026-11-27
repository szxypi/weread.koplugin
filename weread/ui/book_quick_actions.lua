-- Actions stay tied to the page, account and book that opened the menu.
local ButtonDialog=require('ui/widget/buttondialog')
local UI=require('ui/uimanager')
local Popup=require('weread.ui.shelf_popup')
local Protocol=require('weread.lib.protocol')
local _=require('weread.lib.plugin_util').tr
local M={}

function M.available(host,id)
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
    return membership and true or false,finished==true
end

function M.change(host,id,module,current,owner,title)
    -- A second activation must not cancel an existing status/change flow.
    if not current() or host._shelf_state_menu or not host:showShelfState(id) then return false end
    local menu=host._shelf_state_menu
    if not current() or not menu or owner and not Popup.current(owner,menu) then return false end
    return require(module).open(host,id,nil,title)
end

function M.open(host,owner,book,current,local_groups,local_pin)
    if not current() or owner._shelf_popup or type(book)~='table' then return false end
    local raw=book.book_id or book.bookId
    if (type(raw)~='string' and type(raw)~='number') or Protocol.is_mp_book(raw) then return false end
    local id=tostring(raw)
    if id=='' or #id>256 or id:find('[%z%c]') then return false end
    local membership,finished=M.available(host,id)
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
            host:readFromBookList(book,owner,current)
        end)}},
        {{text=_('Book details'),callback=action(function() host:showBookRecord(book) end)}},
    }
    if type(local_groups)=='function' then buttons[#buttons+1]={{text=_('Local groups for this book'),callback=action(local_groups)}} end
    if type(local_pin)=='table' and type(local_pin.callback)=='function' then
        buttons[#buttons+1]={{text=_(local_pin.pinned and 'Remove local pin' or 'Pin on this device'),callback=action(local_pin.callback)}}
    end
    if membership then buttons[#buttons+1]={{text=_('Change cloud membership'),callback=action(function()
        M.change(host,id,'weread.ui.shelf_membership_write',current,owner,book.title)
    end)}} end
    if finished then buttons[#buttons+1]={{text=_('Change finished mark'),callback=action(function()
        M.change(host,id,'weread.ui.finish_change',current,owner)
    end)}} end
    buttons[#buttons+1]={{text=_('Shelf status'),callback=action(function() host:showShelfState(id) end)}}
    buttons[#buttons+1]={{text=_('Cancel'),callback=action(function() end)}}
    dialog=ButtonDialog:new{title=book.title or _('Book details'),buttons=buttons}
    Popup.show(owner,dialog)
    return true
end
return M

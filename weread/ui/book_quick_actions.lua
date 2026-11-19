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
        {{text=_('Shelf status'),callback=action(function() host:showShelfState(id) end)}},
        {{text=_('Cancel'),callback=action(function() end)}},
    }
    dialog=ButtonDialog:new{title=book.title or _('Book details'),buttons=buttons}
    Popup.show(owner,dialog)
    return true
end
return M

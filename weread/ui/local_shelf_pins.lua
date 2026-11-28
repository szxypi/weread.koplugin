-- Local shelf pins are account-scoped and never send account requests.
local Model=require('weread.lib.local_shelf_pins')
local Identity=require('weread.lib.shelf_snapshot')
local _=require('weread.lib.plugin_util').tr
local M={}
function M.available(host,book)
    local db=host.library_db;local id=Identity.persisted_id(book)
    if not id or not db or type(db.accountKey)~='function' or type(db.compareProfileState)~='function'
        or not host.shelf_pins_owner or db:accountKey()~=host.shelf_pins_owner or not Model.valid(host.shelf_pins_state) then return false end
    for _,row in ipairs(host.shelf_regular or {}) do if Identity.persisted_id(row)==id then return true end end
    return false
end
function M.toggle(host,book,current,on_change)
    if not current() or not M.available(host,book) then return false end
    local db,account=host.library_db,host.shelf_pins_owner
    local state,original=host.shelf_pins_state,host.shelf_pins_original
    local value=Model.toggle(state,book)
    if not value then host:showInfo(_('Could not change the local pin.'));return false end
    local ok,saved=pcall(db.compareProfileState,db,Model.KEY,original,value)
    if not ok or saved~=true or not current() or db:accountKey()~=account
        or host.shelf_pins_state~=state or host.shelf_pins_original~=original then
        if current() then host:showInfo(_('Local pins changed or could not be saved. Reopen the bookshelf and try again.')) end
        return false
    end
    host.shelf_pins_state,host.shelf_pins_original=value,value
    on_change();return true
end
return M

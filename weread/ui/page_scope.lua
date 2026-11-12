-- Deferred page actions retain the originating view and account context.
local M={}
function M.capture(host,owner,field)
    field=field or 'shelf_view'
    local function account() return host.library_db and host.library_db:accountKey() end
    local function document() return host.ui and host.ui.document end
    local function source() local shelf=host.settings:get('shelf');return shelf and shelf.source or 'auto' end
    local saved={account=account(),epoch=host.discovery_epoch or 0,session=host._reader_session_gen,
        document=document(),books=host.shelf_regular,groups=host.shelf_groups,state=host.discovery_state,
        detail=host._book_detail_view,source=source(),auth=host.settings.get_auth_scope and host.settings:get_auth_scope()}
    return function()
        if host[field]~=owner or owner and owner._shelf_closed
            or saved.account~=account() or saved.epoch~=(host.discovery_epoch or 0)
            or saved.session~=host._reader_session_gen or saved.document~=document()
            or saved.books~=host.shelf_regular or saved.groups~=host.shelf_groups
            or saved.state~=host.discovery_state or saved.detail~=host._book_detail_view
            or saved.source~=source() then return false end
        if host.settings.get_auth_scope then
            local auth=host.settings:get_auth_scope()
            if not saved.auth then return auth==nil end
            return auth and auth.vid==saved.auth.vid and auth.epoch==saved.auth.epoch
                and host.settings:auth_scope_matches(saved.auth)
        end
        return true
    end
end
function M.guard(current,callback)
    if not callback then return nil end
    return function(...) if current() then return callback(...) end end
end
function M.entries(current,entries)
    if not entries then return nil end
    local result={}
    for _entry_index,item in ipairs(entries) do
        local copy={};for key,value in pairs(item) do copy[key]=value end
        copy.callback=M.guard(current,item.callback)
        if item.sub_item_table then copy.sub_item_table=M.entries(current,item.sub_item_table) end
        result[#result+1]=copy
    end
    return result
end
return M

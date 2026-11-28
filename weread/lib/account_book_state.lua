-- Project pre-account reading data without changing or claiming its owner.
-- The legacy file is retained; each account later receives its own copy.
local M={}
local pending={pending_upload_position=true,pending_upload_reason=true,pending_upload_account=true}
local local_position={last_local_position=true,last_local_account=true}
local home={home_recent_at=true,home_recent_account=true}
local function claimed(value,scope)
    return type(value)=='string' and value~='' and value==scope
end
function M.legacy(metadata,state,fields,scope)
    metadata=type(metadata)=='table' and metadata or {}
    state=type(state)=='table' and state or {}
    local raw={}
    for key,value in pairs(metadata) do if fields[key] then raw[key]=value end end
    for key,value in pairs(state) do if fields[key] then raw[key]=value end end
    local recent=metadata.recent_read_account
    local metadata_owner=metadata._library_account_key
    local common=recent or metadata_owner
    local pending_owner=raw.pending_upload_account or recent or metadata_owner
    local last_owner=raw.last_local_account or recent or metadata_owner
    local home_owner=raw.home_recent_account or recent or metadata_owner
    local result={}
    for key,value in pairs(raw) do
        local allowed
        if pending[key] then allowed=claimed(pending_owner,scope)
        elseif local_position[key] then allowed=claimed(last_owner,scope)
        elseif home[key] then allowed=claimed(home_owner,scope)
        elseif key=='native_home_resume' then
            -- This pointer did not exist in legacy state and cannot acquire an owner there.
            allowed=false
        elseif key=='unindexed_resume' or key=='cb_cloud_view_resume' then
            allowed=type(value)=='table' and claimed(value.owner,scope)
        elseif key=='source_dispatch' then
            -- An unidentifiable dispatch remains a blocking uncertainty, not
            -- permission for a different account to repeat an old request.
            allowed=type(value)~='table' or value.account==nil or claimed(value.account,scope)
        else allowed=claimed(common,scope) end
        if allowed then result[key]=value end
    end
    if result.home_recent_account==nil and claimed(recent,scope) and metadata.recent_read_at~=nil then
        result.home_recent_account=recent;result.home_recent_at=metadata.recent_read_at
    end
    return result
end
return M

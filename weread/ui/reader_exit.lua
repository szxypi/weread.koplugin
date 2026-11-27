-- Close through KOReader so its normal document and position saves run.
local M={}

function M.close(host,reader,scope)
    local document=reader and reader.document
    if host.ui~=reader or not document or host._weread_suspended then return false end
    local account=scope and host.library_db and host.library_db:accountKey()
    if scope and (not account or not host.settings:auth_scope_matches(scope)) then return false end
    if not scope then
        local path=document.file
        reader:onClose()
        if path and reader.showFileManager then reader:showFileManager(path) end
        return true
    end

    local FileManager=require('apps/filemanager/filemanager')
    reader:onClose(false)
    if not FileManager.instance then FileManager:showFiles() end
    local next_host=FileManager.instance and FileManager.instance.weread
    if next_host and next_host.library_db and next_host.library_db:accountKey()==account
        and next_host.settings:auth_scope_matches(scope) then next_host:showHome() end
    return true
end

return M

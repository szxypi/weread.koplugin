-- Conservative, read-only checks for a native chapter's KOReader metadata.
-- A false result means metadata exists; nil means the check could not prove
-- that all supported metadata locations are absent.
local M={}

function M.no_sidecars(path)
    if type(path)~='string' or path=='' or path:find('[%z%c]') then return nil,'invalid' end
    local ok,result,reason=pcall(function()
        local lfs=require('libs/libkoreader-lfs')
        local file=lfs.symlinkattributes(path)
        if not file or file.mode~='file' then return nil,'storage' end
        local digest=require('util').partialMD5(path)
        if type(digest)~='string' or #digest~=32 or not digest:match('^[a-f0-9]+$') then return nil,'storage' end
        local settings=require('docsettings')
        local hash_path=settings:getSidecarDir(path,'hash')
        if type(hash_path)~='string' or hash_path:sub(-#digest-5)~='/'..digest..'.sdr' then return nil,'storage' end
        local history=settings:getHistoryPath(path)
        local paths={settings:getSidecarDir(path,'doc'),settings:getSidecarDir(path,'dir'),hash_path,
            history,history..'.old',path..'.kpdfview.lua'}
        for _,candidate in ipairs(paths) do
            if type(candidate)~='string' or candidate=='' or candidate==path then return nil,'storage' end
            local attr,_,errno=lfs.symlinkattributes(candidate)
            if attr then return false,'metadata' end
            -- KOReader's legacy history name embeds the entire document path.
            -- On filesystems that reject that component as too long, the
            -- rejected pathname cannot refer to an existing history file.
            local too_long=require('ffi').os=='OSX' and 63 or 36
            if errno~=2 and errno~=too_long then return nil,'storage' end
        end
        local after=lfs.symlinkattributes(path)
        if not after or after.mode~='file' or after.dev~=file.dev or after.ino~=file.ino
            or after.size~=file.size or after.modification~=file.modification then return nil,'changed' end
        return true
    end)
    if not ok then return nil,'storage' end
    return result,reason
end

return M

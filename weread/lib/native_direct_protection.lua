-- Conservative, read-only checks for a native chapter's KOReader metadata.
-- A false result means metadata exists; nil means the check could not prove
-- that all supported metadata locations are absent.
local M={}

function M.no_sidecars(path,options)
    if type(path)~='string' or path=='' or path:find('[%z%c]') then return nil,'invalid' end
    options=options or {}
    local ok,result,reason,fingerprint=pcall(function()
        local lfs=require('libs/libkoreader-lfs')
        local file,_,errno=lfs.symlinkattributes(path)
        if not file and (not options.allow_missing or errno~=2) or file and file.mode~='file' then return nil,'storage' end
        local digest=file and require('util').partialMD5(path) or options.fingerprint
        if type(digest)~='string' or #digest~=32 or not digest:match('^[a-f0-9]+$') then return nil,'storage' end
        if options.fingerprint and options.fingerprint~=digest then return nil,'changed' end
        local settings=require('docsettings')
        local root=settings.getSidecarStorage('hash')
        if type(root)~='string' or root=='' then return nil,'storage' end
        local hash_path=root..'/'..digest:sub(1,2)..'/'..digest..'.sdr'
        if file and settings:getSidecarDir(path,'hash')~=hash_path then return nil,'changed' end
        local history=settings:getHistoryPath(path)
        local paths={settings:getSidecarDir(path,'doc'),settings:getSidecarDir(path,'dir'),hash_path,
            history,history..'.old',path..'.kpdfview.lua'}
        for _,candidate in ipairs(paths) do
            if type(candidate)~='string' or candidate=='' or candidate==path then return nil,'storage' end
            local attr,_,candidate_errno=lfs.symlinkattributes(candidate)
            if attr then return false,'metadata' end
            -- KOReader's legacy history name embeds the entire document path.
            -- On filesystems that reject that component as too long, the
            -- rejected pathname cannot refer to an existing history file.
            local too_long=require('ffi').os=='OSX' and 63 or 36
            if candidate_errno~=2 and candidate_errno~=too_long then return nil,'storage' end
        end
        local after=lfs.symlinkattributes(path)
        if file and (not after or after.mode~='file' or after.dev~=file.dev or after.ino~=file.ino
            or after.size~=file.size or after.modification~=file.modification) or not file and after then return nil,'changed' end
        return true,nil,digest
    end)
    if not ok then return nil,'storage' end
    return result,reason,fingerprint
end

return M

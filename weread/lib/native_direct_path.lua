-- Files in this isolated root have no verified Web coordinate provenance.
local M={}
function M.root(settings)
    local dir=type(settings)=='table' and settings.data_dir
    if type(dir)~='string' or dir=='' or dir=='/' or dir:find('[%z%c]') then return nil end
    return dir:gsub('/+$','')..'/native-reader-v1'
end
function M.contains(settings,path)
    local root=M.root(settings)
    return root~=nil and type(path)=='string' and path:sub(1,#root+1)==root..'/'
end
return M

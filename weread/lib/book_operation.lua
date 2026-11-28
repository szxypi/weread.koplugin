-- One descriptor lease shared by cache deletion and download writers.
local M = { NAME = '.weread-book-operation' }
function M.path(root)
    if type(root) ~= 'string' or #root > 4096 or root:sub(1,1) ~= '/' or root:find('[%z%c]') then return end
    root = root:gsub('/+$','')
    if root == '' or root:find('//',1,true) or root:find('/%.%./') or root:match('/%.%.$') or root:find('/%./') or root:match('/%.$') then return end
    return root .. '/' .. M.NAME
end
function M.open(root, create)
    local path = M.path(root)
    if not path then return nil, 'unavailable' end
    local lfs = require('libs/libkoreader-lfs')
    local owner = lfs.symlinkattributes(root)
    if not owner then return nil, 'absent' end
    if owner.mode ~= 'directory' then return nil, 'unavailable' end
    local supported = pcall(require, 'ffi/posix_h')
    if not supported then return nil, 'unsupported' end
    return require('weread.lib.file_lease').open(path, {create=create,empty=true})
end
function M.prepare(root)
    if not M.path(root) then return nil,'unavailable' end
    local lfs=require('libs/libkoreader-lfs')
    local function ensure(path,depth)
        if depth>128 then return false end
        if lfs.attributes(path,'mode')=='directory' then return true end
        local parent=path:match('^(.*)/[^/]+$')
        return parent and parent~='' and ensure(parent,depth+1) and lfs.mkdir(path) or false
    end
    if not ensure(root,0) then return nil,'unavailable' end
    return M.open(root,true)
end
return M

-- Immutable article refreshes. A bounded selector changes only after publication.
-- Old HTML paths and their KOReader sidecars remain available for explicit opening.
local Identity=require('weread.lib.mp_cache_identity')
local Output=require('weread.lib.notes_export_file')
local Epub=require('weread.lib.mp_epub_records')
local M={MAX_VERSIONS=128,MAX_ENTRIES=1024}
local MAGIC='weread-mp-current-v1\n'
local function lfs() return require('libs/libkoreader-lfs') end
local function same(a,b)
    return not a and not b or a and b and a.mode==b.mode and a.dev==b.dev and a.ino==b.ino
        and a.size==b.size and a.modification==b.modification
end
local function directory(root,key)
    local base=Identity.path(root,key)
    if not base then return nil end
    local parent=base:match('^(.*)/[^/]+$')
    if lfs().symlinkattributes(root..'/mp-articles','mode')~='directory'
        or lfs().symlinkattributes(parent,'mode')~='directory' then return nil end
    return parent
end
local function name_ok(name)
    local nonce,ext
    if type(name)=='string' then nonce,ext=name:match('^article%-([a-f0-9]+)%.([a-z]+)$') end
    return nonce and #nonce==16 and (ext=='html' or ext=='epub')
end
M.name_ok=name_ok
local function selector(parent)
    local path=parent..'/current';local info=lfs().symlinkattributes(path)
    if not info then return {path=path} end
    if info.mode~='file' or info.size>128 then return nil end
    local file=io.open(path,'rb');if not file then return nil end
    local raw=file:read(129);file:close()
    local name=raw and raw:sub(1,#MAGIC)==MAGIC and raw:sub(#MAGIC+1):match('^([^\n]+)\n$')
    if not name_ok(name) then return nil end
    return {path=path,info=info,raw=raw,name=name}
end
function M.valid(path,key)
    local epub=path:match('%.epub$')~=nil
    local info=lfs().symlinkattributes(path)
    if not info or info.mode~='file' or info.size<1 or info.size>(epub and Epub.MAX_ARCHIVE or 4*1024*1024) then return false end
    local file=io.open(path,'rb');if not file then return false end
    local head=file:read(4096) or '';file:close()
    if epub then return Epub.header(head,key,path:match('article%-([a-f0-9]+)%.epub$'))~=nil end
    return head:find(Identity.marker(key),1,true)~=nil
end
function M.contains(root,key,path)
    local parent=directory(root,key)
    if not parent or type(path)~='string' or path:sub(1,#parent+1)~=parent..'/' then return false end
    local name=path:sub(#parent+2)
    return (name=='article.html' or name_ok(name)) and M.valid(path,key)
end
function M.resolve(root,key)
    local parent=directory(root,key)
    if not parent then return nil,'none' end
    local state=selector(parent)
    if not state then return nil,'invalid' end
    if not state.name then return nil,'none' end
    local path=parent..'/'..state.name
    if not M.valid(path,key) then return nil,'invalid' end
    return path,'current'
end
function M.capture(root,key)
    local parent=directory(root,key);if not parent then return nil end
    local state=selector(parent);if not state then return nil end
    local path=parent..'/'..(state.name or 'article.html')
    local info=lfs().symlinkattributes(path)
    if info and info.mode~='file' or state.name and not M.valid(path,key) then return nil end
    return {root=root,key=key,parent=parent,parent_info=lfs().symlinkattributes(parent),selector=state,path=path,info=info}
end
function M.matches(snapshot)
    local parent=directory(snapshot.root,snapshot.key)
    local info=parent and lfs().symlinkattributes(parent)
    if not info or info.dev~=snapshot.parent_info.dev or info.ino~=snapshot.parent_info.ino then return false end
    local state=selector(parent)
    return state and state.raw==snapshot.selector.raw and same(state.info,snapshot.selector.info)
        and same(lfs().symlinkattributes(snapshot.path),snapshot.info)
end
function M.points_to(root,key,name)
    local parent=directory(root,key);local state=parent and selector(parent)
    return state and state.name==name
end
function M.publish(snapshot,name)
    if not name_ok(name) or not M.valid(snapshot.parent..'/'..name,snapshot.key) or not M.matches(snapshot) then return false end
    local raw=MAGIC..name..'\n';local output
    local ok,result=pcall(function()
        output=Output.create(snapshot.parent,'current','json')
        if not output or not output:write(raw) or not output:sync() or not output:accept(#raw) or not M.matches(snapshot) then return false end
        if not os.rename(output.path,snapshot.selector.path) then return false end
        local state=selector(snapshot.parent)
        return state and state.raw==raw and M.valid(snapshot.parent..'/'..name,snapshot.key)
    end)
    if output then output:abort() end
    return ok and result==true
end
function M.list(root,key)
    local snapshot=M.capture(root,key);if not snapshot then return nil end
    local entries,count={},0
    for name in lfs().dir(snapshot.parent) do
        count=count+1;if count>M.MAX_ENTRIES then return nil end
        if name=='article.html' or name_ok(name) then
            local path=snapshot.parent..'/'..name
            if M.valid(path,key) then
                if #entries>=M.MAX_VERSIONS then return nil end
                entries[#entries+1]={path=path,info=lfs().symlinkattributes(path),current=path==snapshot.path}
            end
        end
    end
    table.sort(entries,function(a,b)
        if a.current~=b.current then return a.current end
        if a.info.modification~=b.info.modification then return a.info.modification>b.info.modification end
        return a.path<b.path
    end)
    return entries
end
M.same=same
return M

-- Bounded, content-addressed records for file-backed Web chapter images.
local Crypto=require('weread.lib.crypto')
local M={}
local MAX_IMAGE=512*1024*1024
local MAX_RECEIPT=12*1024*1024
local MAX_ITEMS=20000
local CHUNK=65536
local ok_sha,sha=pcall(require,'ffi/sha2')
local hash=ok_sha and type(sha)=='table' and type(sha.sha256)=='function' and sha.sha256 or Crypto.sha256_hex

local function valid_name(name)
    return type(name)=='string' and #name>0 and #name<=255 and name~='.' and name~='..'
        and not name:find('[%z%c/\\]')
end
local function encode(name)
    return (name:gsub('.',function(c) return string.format('%02x',c:byte()) end))
end
local function decode(value)
    if #value%2~=0 or not value:match('^[0-9a-f]+$') then return nil end
    local name=value:gsub('..',function(byte) return string.char(tonumber(byte,16)) end)
    return valid_name(name) and name or nil
end
local function lfs_module()
    local ok,lfs=pcall(require,'libs/libkoreader-lfs')
    if not ok then ok,lfs=pcall(require,'lfs') end
    return ok and lfs or nil
end
local function digest_file(path)
    local lfs=lfs_module()
    local parent=path:match('^(.*)/[^/]+$')
    if not lfs or not parent or (lfs.symlinkattributes and lfs.symlinkattributes(parent,'mode')
        or lfs.attributes(parent,'mode'))~='directory'
        or (lfs.symlinkattributes and lfs.symlinkattributes(path,'mode')
        or lfs.attributes(path,'mode'))~='file' then return nil end
    local file=io.open(path,'rb');if not file then return nil end
    local size,chain=0,hash('weread-web-image-v1')
    while true do
        local bytes,err=file:read(CHUNK)
        if err then file:close();return nil end
        if not bytes then break end
        size=size+#bytes
        if size>MAX_IMAGE then file:close();return nil end
        chain=hash(chain..hash(bytes))
    end
    if not file:close() or size==0 then return nil end
    return size,hash(chain..':'..size)
end
local function receipt_path(workspace,digest)
    if not workspace or type(workspace.web_asset_receipt_dir)~='string' or type(digest)~='string'
        or #digest~=64 or not digest:match('^[0-9a-f]+$') then return nil end
    return workspace.web_asset_receipt_dir..'/images-'..digest..'.txt'
end

function M.stage(workspace,assets)
    if type(assets)~='table' or #assets>MAX_ITEMS or not workspace or type(workspace.asset_dir)~='string' then
        error('invalid web image list',0)
    end
    local names,seen={},{}
    local count=0
    for key in pairs(assets) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#assets then error('invalid web image list',0) end
        count=count+1
    end
    if count~=#assets then error('invalid web image list',0) end
    for _,asset in ipairs(assets) do
        local name=type(asset)=='table' and type(asset.href)=='string' and asset.href:match('^images/([^/]+)$')
        if not valid_name(name) or asset.path~=workspace.asset_dir..'/'..name then error('invalid web image',0) end
        if not seen[name] then seen[name]=true;names[#names+1]=name end
    end
    table.sort(names)
    local lines={}
    for _,name in ipairs(names) do
        local size,digest=digest_file(workspace.asset_dir..'/'..name)
        if not size then error('unreadable web image',0) end
        lines[#lines+1]=encode(name)..':'..size..':'..digest..'\n'
    end
    local raw=table.concat(lines)
    if #raw>MAX_RECEIPT then error('web image receipt too large',0) end
    local digest=Crypto.sha256_hex(raw)
    local path=assert(receipt_path(workspace,digest))
    local lfs=lfs_module()
    if not lfs or (lfs.symlinkattributes and lfs.symlinkattributes(workspace.web_asset_receipt_dir,'mode')
        or lfs.attributes(workspace.web_asset_receipt_dir,'mode'))~='directory' then error('invalid web image receipt directory',0) end
    local part=path..'.part'
    local mode=lfs.symlinkattributes and lfs.symlinkattributes(part,'mode') or lfs.attributes(part,'mode')
    local removed=os.remove(part)
    if mode and not removed then error('invalid web image receipt temporary file',0) end
    local target=lfs.symlinkattributes and lfs.symlinkattributes(path,'mode') or lfs.attributes(path,'mode')
    if target=='file' then
        local file=io.open(path,'rb')
        if file then
            local previous,read_err=file:read(#raw+1)
            if file:close() and not read_err and (previous or '')==raw then return digest end
        end
    end
    local out=assert(io.open(part,'wb'))
    local wrote,write_err=out:write(raw);local closed,close_err=out:close()
    if not wrote or not closed then os.remove(part);error(write_err or close_err or 'web image receipt write failed',0) end
    local renamed,err=os.rename(part,path)
    if not renamed then os.remove(part);error(err or 'web image receipt publish failed',0) end
    return digest
end

local function records(workspace,digest)
    local path=receipt_path(workspace,digest)
    local lfs=lfs_module()
    if not path or not lfs or (lfs.symlinkattributes and lfs.symlinkattributes(workspace.web_asset_receipt_dir,'mode')
        or lfs.attributes(workspace.web_asset_receipt_dir,'mode'))~='directory'
        or (lfs.symlinkattributes and lfs.symlinkattributes(path,'mode')
        or lfs.attributes(path,'mode'))~='file' then return false end
    local file=io.open(path,'rb');if not file then return false end
    local raw,err=file:read(MAX_RECEIPT+1);local closed=file:close()
    raw=raw or ''
    if err or not closed or #raw>MAX_RECEIPT or Crypto.sha256_hex(raw)~=digest then return false end
    local entries,previous={},nil
    for line in raw:gmatch('([^\n]+)\n') do
        local encoded,size,expected=line:match('^([0-9a-f]+):(%d+):([0-9a-f]+)$')
        local name=encoded and decode(encoded)
        if not name or previous and name<=previous or #entries>=MAX_ITEMS or #expected~=64 then return nil end
        entries[#entries+1]={name=name,size=size,digest=expected};previous=name
    end
    local lines=0;for _ in raw:gmatch('\n') do lines=lines+1 end
    if lines~=#entries or #raw>0 and raw:sub(-1)~='\n' then return nil end
    return entries
end

-- Read authenticated names without trusting the continued existence of old
-- image files. This can identify stale files left by interrupted downloads.
function M.names(workspace,digest)
    local entries=records(workspace,digest)
    if not entries then return false end
    local names={}
    for _,entry in ipairs(entries) do names[#names+1]=entry.name end
    return true,names
end

local function verify(workspace,digest,inspect)
    local entries=records(workspace,digest)
    if not entries then return false end
    local names={}
    for _,entry in ipairs(entries) do
        local actual_size,actual=inspect(workspace.asset_dir..'/'..entry.name)
        if not actual_size or tostring(actual_size)~=entry.size or actual~=entry.digest then return false end
        names[#names+1]=entry.name
    end
    return true,names
end

function M.verify(workspace,digest)
    return verify(workspace,digest,digest_file)
end

function M.batch_verifier(workspace)
    local inspect=require('weread.lib.download_file_checks').memoize(digest_file)
    return function(digest) return verify(workspace,digest,inspect) end
end

return M

-- Preserve shared hash records before opening an old managed HTML. Recovery
-- creates a separate version; no path or timestamp infers record ownership.
local Content=require('weread.lib.content')
local Identity=require('weread.lib.mp_cache_identity')
local Versions=require('weread.lib.mp_cache_versions')
local Data=require('weread.lib.mp_record_data')
local Crypto=require('weread.lib.crypto')
local M={}
local function fs() return require('libs/libkoreader-lfs') end
local function fail() error('mp_records/unavailable',0) end
local function read(path,max,expected)
    local info=fs().symlinkattributes(path)
    if not info or info.mode~='file' or info.size>max or expected and not Versions.same(info,expected) then fail() end
    local file=io.open(path,'rb');if not file then fail() end
    local raw=file:read(max+1);file:close()
    if not raw or #raw>max or #raw~=info.size or not Versions.same(info,fs().symlinkattributes(path)) then fail() end
    return raw,info
end
function M.capture(settings,book,article,path)
    local key=Identity.key(book,article);if not key then fail() end
    local root=Content.book_resolved_dir(settings,book.book_id or book.bookId,book)
    if type(root)~='string' then fail() end;root=root:gsub('/+$','')
    local base=Identity.path(root,key);if not base or type(path)~='string' then fail() end
    if path:sub(1,#root+13)~=root..'/mp-articles/' then
        local legacy=Content.mp_article_legacy_path(settings,book,article)
        if path~=legacy and path~=legacy:gsub('%.html$','.epub') then fail() end
        local allowed=Identity.legacy_allowed(book,article,book.mp_articles or (settings:get('books',{})[book.book_id or book.bookId] or {}).mp_articles,
            function(row) return Content.mp_article_legacy_path(settings,book,row) end)
        if not allowed or fs().symlinkattributes(path,'mode')~='file' then fail() end
        return nil,'legacy'
    end
    if not Versions.contains(root,key,path) then fail() end
    local snapshot=Versions.capture(root,key);if not snapshot then fail() end
    local file=io.open(path,'rb');if not file then fail() end
    local head=file:read(1024) or '';file:close()
    local revision=head:match('<meta name="weread%-mp%-cache%-revision" content="([a-f0-9]+)"/>')
    return {root=root,key=key,path=path,info=fs().symlinkattributes(path),snapshot=snapshot,stamped=revision and #revision==16 or false}
end
function M.matches(settings,book,article,input)
    local ok,now=pcall(M.capture,settings,book,article,input.path)
    return ok and now and now.root==input.root and now.key==input.key and Versions.same(input.info,now.info)
        and Versions.matches(input.snapshot)
end
function M.hash_directory(path)
    local Doc=require('docsettings');local directory=Doc:getSidecarDir(path,'hash')
    local base=Doc.getSidecarStorage('hash')
    if type(base)~='string' or directory:sub(1,#base+1)~=base..'/' then fail() end
    return directory
end
function M.freeze(input)
    local Doc=require('docsettings');local directory=M.hash_directory(input.path)
    local filename=Doc.getSidecarFilename(input.path)
    local beside=Doc:getSidecarDir(input.path,'doc');local folder=Doc:getSidecarDir(input.path,'dir')
    local history=Doc:getHistoryPath(input.path)
    local candidates={{'primary',directory..'/'..filename},{'backup',directory..'/'..filename..'.old'},
        {'beside',beside..'/'..filename},{'beside_backup',beside..'/'..filename..'.old'},
        {'folder',folder..'/'..filename},{'folder_backup',folder..'/'..filename..'.old'},
        {'legacy_beside',beside..'/'..input.path:match('[^/]+$')..'.lua'},
        {'history',history},{'history_backup',history..'.old'},{'compatibility',input.path..'.kpdfview.lua'}}
    local rows={}
    for _i,candidate in ipairs(candidates) do
        local kind,path=candidate[1],candidate[2]
        local parent=path:match('^(.*)/[^/]+$')
        local mode=parent and fs().symlinkattributes(parent,'mode');if mode and mode~='directory' then fail() end
        local info=fs().symlinkattributes(path)
        if info then
            local value=read(path,Data.MAX_BYTES,info)
            if #value>0 then rows[#rows+1]={kind=kind,raw=value} end
        end
    end
    return rows
end
function M.preserve(store,input,rows)
    if not store then if #rows>0 then fail() end;return true end
    if not store:save(input.key,rows) then fail() end
    return true
end
function M.prepare(store,input)
    local raw=read(input.path,Data.MAX_BYTES,input.info)
    if not Versions.matches(input.snapshot) then fail() end
    if not store then return {ok=true,rows={},source_sha256=Crypto.sha256_hex(raw)} end
    local saved=store:list(input.key);if not saved then fail() end
    return {ok=true,rows=saved,source_sha256=Crypto.sha256_hex(raw)}
end
function M.write(input,stage,sha256)
    local raw=read(input.path,Data.MAX_BYTES,input.info)
    if Crypto.sha256_hex(raw)~=sha256 or not Versions.matches(input.snapshot) then fail() end
    local start=raw:find('<head>',1,true);local stop=raw:find('</head>',1,true)
    if not start or start>256 or not stop then fail() end
    local nonce=stage.version_name:match('^article%-([a-f0-9]+)%.html$');if not nonce or #nonce~=16 then fail() end
    local head=raw:sub(start+6,stop-1):gsub('<meta name="weread%-mp%-cache%-revision" content="[a-f0-9]+"/>\n?','')
    local html=raw:sub(1,start+5)..'\n<meta name="weread-mp-cache-revision" content="'..nonce..'"/>'..head..raw:sub(stop)
    if #html>Data.MAX_BYTES or not stage.output:write(html) or not stage.output:sync() then fail() end
    return {ok=true,bytes=#html,images=0,image_bytes=0}
end
local function empty_target(path)
    local Doc=require('docsettings');local filename=Doc.getSidecarFilename(path)
    for _i,location in ipairs({'doc','dir','hash'}) do
        local dir=Doc:getSidecarDir(path,location)
        local mode=fs().symlinkattributes(dir,'mode');if mode and mode~='directory' then return false end
        for _j,name in ipairs({filename,filename..'.old',path:match('[^/]+$')..'.lua'}) do
            if fs().symlinkattributes(dir..'/'..name) then return false end
        end
    end
    for _i,candidate in ipairs({Doc:getHistoryPath(path),Doc:getHistoryPath(path)..'.old',path..'.kpdfview.lua'}) do
        if fs().symlinkattributes(candidate) then return false end
    end
    return true
end
function M.restore(store,input,id,path)
    if id==false then return empty_target(path) end
    local raw=store and store:get(input.key,id);if not raw then fail() end
    local data=Data.record(raw)
    if not empty_target(path) then fail() end
    -- These two fields describe the source file's engine cache and checksum.
    data.doc_path=path;data.cache_file_path=nil;data.partial_md5_checksum=nil
    local Doc=require('docsettings');local target=Doc:open(path);target.data=data
    local dir=target:flush();if not dir then fail() end
    local saved=Data.read(read(dir..'/'..Doc.getSidecarFilename(path),Data.MAX_BYTES))
    if not Data.same(data,saved) then fail() end
    return true
end
return M

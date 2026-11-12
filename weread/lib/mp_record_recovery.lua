-- Preserve shared hash records before opening an old managed HTML. Recovery
-- creates a separate version; no path or timestamp infers record ownership.
local Content=require('weread.lib.content')
local Identity=require('weread.lib.mp_cache_identity')
local Versions=require('weread.lib.mp_cache_versions')
local Data=require('weread.lib.mp_record_data')
local Crypto=require('weread.lib.crypto')
local Assets=require('weread.lib.mp_record_assets')
local M={}
local function fs() return require('libs/libkoreader-lfs') end
local function fail() error('mp_records/unavailable',0) end
local function inode(a,b) return a and b and a.mode==b.mode and a.dev==b.dev and a.ino==b.ino end
local function optional(path)
    local info,_,code=fs().symlinkattributes(path)
    if not info and code~=2 then fail() end
    return info
end
local function capture_target(root,key)
    local container=optional(root..'/mp-articles')
    local parent=container and optional(Identity.path(root,key):match('^(.*)/[^/]+$'))
    if container and container.mode~='directory' or parent and parent.mode~='directory' then fail() end
    if parent then local snapshot=Versions.capture(root,key);if not snapshot then fail() end;return snapshot end
    return false,container or false
end
local function target_matches(input)
    if input.snapshot then return Versions.matches(input.snapshot) end
    if not input.legacy then return false end
    local snapshot,container=capture_target(input.root,input.key)
    -- Another article may create the shared container while this chooser is
    -- open. The source root must still match and our own directory stay absent.
    return not snapshot and (not input.container or inode(input.container,container))
end
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
        local id=book.book_id or book.bookId
        local saved
        if settings.get_book then saved=settings:get_book(id) else saved=settings:get('books',{})[id] end
        local stored=(saved or {}).mp_articles
        local allowed=Identity.legacy_allowed(book,article,stored or book.mp_articles,
            function(row) return Content.mp_article_legacy_path(settings,book,row) end)
        if not allowed or fs().symlinkattributes(path,'mode')~='file' then fail() end
        local epub=path:match('%.epub$') and true or nil
        local root_info=fs().symlinkattributes(root);if not root_info or root_info.mode~='directory' then fail() end
        local snapshot,container=capture_target(root,key)
        local file=io.open(path,'rb');if not file then fail() end
        local head=file:read(4096) or '';file:close()
        local marked=not epub and head:match('<meta name="weread%-mp%-cache%-key" content="([a-f0-9]+)"/>')
        if marked and marked~=key then fail() end
        return {root=root,key=key,path=path,info=fs().symlinkattributes(path),root_info=root_info,legacy=true,
            asset_name=Content.mp_article_asset_name(book,article),snapshot=snapshot,container=container,stamped=false,
            catalog_origin=stored~=nil and 'stored' or 'provided',epub=epub}
    end
    if not Versions.contains(root,key,path) then fail() end
    local snapshot=Versions.capture(root,key);if not snapshot then fail() end
    if path:match('%.epub$') then
        return {root=root,key=key,path=path,info=fs().symlinkattributes(path),snapshot=snapshot,epub=true,stamped=true}
    end
    local file=io.open(path,'rb');if not file then fail() end
    local head=file:read(1024) or '';file:close()
    local revision=head:match('<meta name="weread%-mp%-cache%-revision" content="([a-f0-9]+)"/>')
    return {root=root,key=key,path=path,info=fs().symlinkattributes(path),snapshot=snapshot,stamped=revision and #revision==16 or false}
end
function M.matches(settings,book,article,input)
    local ok,now=pcall(M.capture,settings,book,article,input.path)
    return ok and now and now.root==input.root and now.key==input.key and Versions.same(input.info,now.info)
        and input.legacy==now.legacy and input.epub==now.epub and (not input.legacy or inode(input.root_info,now.root_info)
            and input.catalog_origin==now.catalog_origin) and target_matches(input)
end
-- Stage.create may create the first identity directory. Accept only that empty
-- target; an existing selector/body cannot become authorized by this transition.
function M.bind_stage(input,stage)
    if not input.legacy then return true end
    if stage.root~=input.root or stage.key~=input.key or not inode(input.root_info,fs().symlinkattributes(input.root)) then return false end
    if input.snapshot then return Versions.matches(input.snapshot) end
    local snapshot=stage.version_snapshot
    if not snapshot or snapshot.selector.info or snapshot.selector.name or snapshot.info
        or input.container and not inode(input.container,fs().symlinkattributes(input.root..'/mp-articles')) then return false end
    input.snapshot=snapshot;input.container=nil
    return Versions.matches(snapshot)
end
function M.bind_assets(input,rows)
    if not input.legacy or input.epub then return true end
    if not Assets.matches(input,rows) then return false end
    input.assets=rows;return true
end
function M.assets_match(input) return not input.legacy or input.epub or Assets.matches(input,input.assets) end
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
    if not target_matches(input) then fail() end
    local saved={}
    if store then saved=store:list(input.key);if not saved then fail() end end
    -- No copy is needed for an ordinary legacy read without saved records.
    -- It must not require parsing resources or loading a large embedded image.
    if input.legacy and #saved==0 then return {ok=true,rows={}} end
    if input.epub then
        if #saved==0 then return {ok=true,rows={}} end
        local plan=require('weread.lib.mp_epub_records').inspect(input.path,input.info,input.key)
        return {ok=true,rows=saved,source_sha256=plan.source_sha256}
    end
    local raw=read(input.path,Data.MAX_BYTES,input.info)
    return {ok=true,rows=saved,source_sha256=Crypto.sha256_hex(raw),assets=input.legacy and Assets.inspect(input,raw) or nil}
end
function M.write(input,stage,sha256)
    if input.epub then
        if stage.format~='epub' or not target_matches(input) then fail() end
        return require('weread.lib.mp_epub_records').write(input,stage.output,
            stage.version_name:match('^article%-([a-f0-9]+)%.epub$'),sha256)
    end
    local raw=read(input.path,Data.MAX_BYTES,input.info)
    if Crypto.sha256_hex(raw)~=sha256 or not target_matches(input) then fail() end
    local images,image_bytes=0,0
    if input.legacy then raw,images,image_bytes=Assets.copy(input,stage,raw) end
    local finish,stop
    if input.legacy then raw,finish,stop=Assets.header(raw)
    else
        local start=raw:find('<head>',1,true);stop=raw:find('</head>',1,true)
        if not start or start>256 or not stop then fail() end;finish=start+5
    end
    local nonce=stage.version_name:match('^article%-([a-f0-9]+)%.html$');if not nonce or #nonce~=16 then fail() end
    local head=raw:sub(finish+1,stop-1):gsub('<meta name="weread%-mp%-cache%-revision" content="[a-f0-9]+"/>\n?','')
    if input.legacy then head=head:gsub('<meta name="weread%-mp%-cache%-key" content="[a-f0-9]+"/>\n?','') end
    local identity=input.legacy and Identity.marker(input.key)..'\n' or ''
    local html=raw:sub(1,finish)..'\n<meta name="weread-mp-cache-revision" content="'..nonce..'"/>'..identity..head..raw:sub(stop)
    if #html>Data.MAX_BYTES or not stage.output:write(html) or not stage.output:sync() then fail() end
    return {ok=true,bytes=#html,images=images,image_bytes=image_bytes}
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

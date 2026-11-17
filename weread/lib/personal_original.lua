-- Associate a confirmed personal PDF upload with its original local file.
-- These account-scoped records are local-only; they never enable cloud sync.
local Model=require('weread.lib.personal_upload')
local Read=require('weread.lib.read_access')
local Content=require('weread.lib.content')
local M={}
local pending
function M.arm(path)
    if type(path)~='string' or path=='' then return false end
    pending={path=path,started=os.time()};return true
end
function M.disarm(path)
    if pending and pending.path==path then pending=nil end
end
function M.take(path)
    local value=pending
    if not value then return false end
    local age=os.time()-value.started
    if age<0 or age>30 then pending=nil;return false end
    if value.path~=path then return false end
    pending=nil;return true
end
local function key(id)
    id=Read.display_book_id(id)
    return id and 'personal_original_pdf:'..id or nil
end
local function inside(path,dir)
    if type(dir)~='string' or dir=='' then return false end
    return path:sub(1,#dir:gsub('/+$','')+1)==dir:gsub('/+$','')..'/'
end
-- Match the reader's existing WeRead-file detection so opening this path does
-- not attach it to any cloud book or automatically report its reading position.
function M.local_only_path(settings,path)
    if type(settings)~='table' or type(settings.cache_dir)~='string' or settings.cache_dir==''
        or type(path)~='string' or inside(path,settings.cache_dir) then return false end
    local books=settings:get('books',{})
    if type(books)~='table' then return false end
    for id,book in pairs(books) do
        if type(book)=='table' then
            local ok,dir=pcall(Content.book_resolved_dir,settings,id,book)
            if not ok or type(dir)~='string' or inside(path,dir) or path==book.cached_file then return false end
        end
    end
    return true
end
local function owner(host)
    if not host.library_db or type(host.library_db.accountKey)~='function' then return nil end
    local ok,value=pcall(host.library_db.accountKey,host.library_db)
    return ok and value or nil
end
local function matches(input)
    local ok,value=pcall(Model.matches,input)
    return ok and value==true
end
function M.remember(host,id,input)
    local name=key(id);local account=owner(host)
    if not name or not account or type(input)~='table' or type(input.name)~='string'
        or not input.name:lower():match('%.pdf$') or not M.local_only_path(host.settings,input.path)
        or not matches(input) then return false end
    local info=input.identity
    if type(info)~='table' or type(info.dev)~='number' or type(info.ino)~='number'
        or type(info.size)~='number' or type(info.modification)~='number' or type(info.change)~='number' then return false end
    local data={path=input.path,identity={mode=info.mode,dev=info.dev,ino=info.ino,size=info.size,
        modification=info.modification,change=info.change}}
    local ok,saved=pcall(host.library_db.putProfileState,host.library_db,name,data)
    if not ok or saved~=true or account~=owner(host) then return false end
    local read,stored=pcall(host.library_db.getProfileState,host.library_db,name)
    return read and type(stored)=='table' and stored.path==data.path and type(stored.identity)=='table'
        and matches(stored) and account==owner(host)

end
function M.resolve(host,id)
    local name=key(id);local account=owner(host)
    if not name or not account then return nil end
    local ok,data=pcall(host.library_db.getProfileState,host.library_db,name)
    if not ok or type(data)~='table' or type(data.path)~='string' or type(data.identity)~='table'
        or not data.path:lower():match('%.pdf$') or not M.local_only_path(host.settings,data.path) then return nil end
    local captured,current=pcall(Model.capture,data.path)
    if not captured or not current or not matches(data) or account~=owner(host) then return nil end
    return data.path
end
return M

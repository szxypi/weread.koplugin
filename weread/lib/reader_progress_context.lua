-- Snapshot the native viewport; percentages refer only to the open file.
local M={}
local function finite(n) return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function position(document)
    if type(document.getCurrentPos)~='function' then return nil end
    local ok,value=pcall(document.getCurrentPos,document)
    return ok and finite(value) and value or nil
end
local function account(host)
    local db=host.library_db
    if not db or type(db.accountKey)~='function' then return nil,true end
    local ok,value=pcall(db.accountKey,db)
    return value,ok
end
local function scope(host)
    local settings=host.settings
    if not settings or type(settings.get_auth_scope)~='function' then return nil,true end
    local ok,value=pcall(settings.get_auth_scope,settings)
    return value,ok
end
function M.capture(host)
    local ui=host and host.ui;local document=ui and ui.document
    if not document or type(document.file)~='string' or document.file==''
        or type(ui.getCurrentPage)~='function' or type(ui.handleEvent)~='function'
        or type(document.getPageCount)~='function' then return nil end
    local ok,page,total=pcall(function() return ui:getCurrentPage(),document:getPageCount() end)
    if not ok or not finite(page) or not finite(total) or page<1 or total<1
        or page%1~=0 or total%1~=0 or total>10000000 or page>total then return nil end
    local account_value,account_ok=account(host)
    local scope_value,scope_ok=scope(host)
    if not account_ok or not scope_ok then return nil end
    local mode=ui.view and ui.view.view_mode
    local pos=position(document)
    local percent=page/total*100
    local height=type(document.info)=='table' and document.info.doc_height
    if mode=='scroll' and ui.rolling and (not finite(pos) or not finite(height) or height<=0) then return nil end
    if mode=='scroll' and finite(pos) and finite(height) and height>0 then percent=pos/height*100 end
    percent=math.max(0,math.min(100,percent))
    return {ui=ui,document=document,file=document.file,page=page,total=total,mode=mode,pos=pos,
        percent=percent,session=host._reader_session_gen,account=account_value,scope=scope_value}
end
function M.current(host,snapshot)
    if not host or not snapshot or host.ui~=snapshot.ui or snapshot.ui.document~=snapshot.document
        or snapshot.document.file~=snapshot.file or host._reader_session_gen~=snapshot.session then return false end
    local current_account,account_ok=account(host)
    local now,scope_ok=scope(host)
    if not account_ok or not scope_ok or current_account~=snapshot.account then return false end
    local settings=host.settings
    if snapshot.scope then
        if not settings or type(settings.auth_scope_matches)~='function' then return false end
        local ok,matches=pcall(settings.auth_scope_matches,settings,snapshot.scope)
        if not ok or matches~=true then return false end
    elseif now~=nil then return false end
    local fresh=M.capture(host)
    return fresh and fresh.page==snapshot.page and fresh.total==snapshot.total
        and fresh.mode==snapshot.mode and fresh.pos==snapshot.pos or false
end
return M

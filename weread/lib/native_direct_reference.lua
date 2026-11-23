-- Native chapter selection references require independent native and Web
-- source verification both when displayed and immediately before dispatch.
local Access=require('weread.lib.native_read_access')
local Currentness=require('weread.lib.source_currentness')
local Cache=require('weread.lib.native_direct_cache')
local Path=require('weread.lib.native_direct_path')
local Position=require('weread.lib.native_direct_position')
local Reference=require('weread.lib.selection_reference')
local M={}
local function active(settings,native,web,current)
    local ok,value=pcall(current)
    return ok and value==true and Access.matches(settings,native) and Currentness.matches(settings,web)
end
function M.capture(client,settings,entry,file,input,native,web,current,bookmark)
    if type(current)~='function' or not Path.contains(settings,file) or not active(settings,native,web,current) then return nil,'invalid' end
    local raw,why=Position.verified_source(client,settings,entry,file,native,web,current)
    if not raw then return nil,why end
    local ref=bookmark and require('weread.lib.bookmark_reference') or Reference
    local row,reason=ref.capture_direct(input,entry,file,raw)
    if not active(settings,native,web,current) then return nil,'session_changed' end
    return row,reason
end
function M.verify(client,settings,native,row,file,current,bookmark)
    if type(current)~='function' or not Path.contains(settings,file) or type(native)~='table'
        or type(native.scope)~='table' or not Access.matches(settings,native) then return nil,'invalid' end
    local web=Currentness.capture(settings)
    if not web or not web.web or not web.web.cookies or web.web.cookies.wr_vid~=native.scope.vid then return nil,'web_expired' end
    local function live() return active(settings,native,web,current) end
    if not live() then return nil,'session_changed' end
    local entry=Cache.identify(settings,native.scope.vid,file,live)
    if not entry or not live() then return nil,'source_changed' end
    local raw,why=Position.verified_source(client,settings,entry,file,native,web,live)
    if not raw then return nil,why end
    local ref=bookmark and require('weread.lib.bookmark_reference') or Reference
    local verified,reason=ref.verify_direct(row,entry,file,raw)
    if not live() then return nil,'session_changed' end
    return verified,reason,entry.book_version
end
function M.restore(client,settings,entry,file,key,native,web,current)
    if type(current)~='function' or not Path.contains(settings,file) or not active(settings,native,web,current) then return nil,'invalid' end
    local raw,why=Position.verified_source(client,settings,entry,file,native,web,current)
    if not raw then return nil,why end
    local row,reason=Reference.restore_direct(entry,file,key,raw)
    if not active(settings,native,web,current) then return nil,'session_changed' end
    return row,reason
end
return M

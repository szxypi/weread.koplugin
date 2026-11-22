-- One-use transfer of a verified cloud target across ReaderUI:switchDocument.
local Access=require('weread.lib.native_read_access')
local Cache=require('weread.lib.native_direct_cache')
local Cloud=require('weread.lib.native_direct_cloud')
local Currentness=require('weread.lib.source_currentness')
local Identity=require('weread.lib.book_file_identity')
local Path=require('weread.lib.native_direct_path')
local M={}
function M.prepare(host,ctx,resolved,on_open,now)
    if type(ctx)~='table' or host._native_direct_position~=ctx or type(ctx.is_current)~='function'
        or not ctx.is_current() or type(ctx.scope)~='table' or type(ctx.session)~='number'
        or type(resolved)~='table' or not Path.contains(host.settings,resolved.path)
        or not Cloud.valid_target(resolved.target) or not Cache.valid_entry(resolved.entry,resolved.target.book_id,ctx.scope.vid)
        or resolved.entry.chapter_uid~=resolved.target.chapter_uid or resolved.entry.chapter_idx~=resolved.target.chapter_idx
        or type(resolved.entry.file_id)~='string' or #resolved.entry.file_id~=64
        or not resolved.entry.file_id:match('^[a-f0-9]+$') or type(on_open)~='function' then return nil end
    now=now or os.time;local started=now();local used=false
    return function(reader)
        if used then return false end
        used=true
        local age=now()-started;local next_host=reader and reader.weread
        local doc=next_host and next_host.ui and next_host.ui.document
        if age<0 or age>180 or host._reader_session_gen~=ctx.session+1
            or not host.settings:auth_scope_matches(ctx.scope) or not Access.matches(host.settings,ctx.native)
            or not Currentness.matches(host.settings,ctx.web) or not next_host or next_host==host
            or not doc or doc~=reader.document or doc==ctx.document or doc.file~=resolved.path
            or not Access.matches(next_host.settings,ctx.native) or not Currentness.matches(next_host.settings,ctx.web) then return false end
        local identity=Identity.read_document(doc,resolved.target.book_id)
        if identity.file_id~=resolved.entry.file_id or identity.book_id~=resolved.target.book_id
            or identity.book_version~=resolved.entry.book_version then return false end
        local ok,value=pcall(on_open,next_host,resolved.entry,resolved.target,ctx.native,ctx.web)
        return ok and value==true
    end
end
return M

-- Background worker entry point: native source -> isolated local-only EPUB.
-- Only the bounded path/identity receipt leaves the worker, not chapter text.
local Access=require('weread.lib.native_read_access')
local Direct=require('weread.lib.native_direct_source')
local Cache=require('weread.lib.native_direct_cache')
local M={}

function M.build(client,settings,book,chapter,expected,options)
    if type(book)~='table' or type(chapter)~='table' or type(expected)~='table'
        or type(options)~='table' or type(options.is_current)~='function' then return nil,'invalid' end
    local current,selected=Access.guard(settings,options.is_current)
    if not current or type(selected.scope)~='table'
        or type(selected.scope.vid)~='string' or selected.fingerprint~=expected.access_fingerprint then
        return nil,'session_changed'
    end
    if not current() then return nil,'session_changed' end
    local prepared,why=Direct.fetch(client,settings,book.book_id,chapter.chapterUid,expected,
        {is_current=current,allow_missing_images=options.allow_missing_images==true})
    if not prepared then return nil,why end
    if not current() then return nil,'session_changed' end
    return Cache.publish(settings,selected.scope.vid,book,chapter,prepared,current,options.capacity)
end
return M

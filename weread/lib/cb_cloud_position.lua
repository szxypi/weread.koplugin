-- Read-only CB_ projection. Does not create upload candidates or relax the
-- numeric-book/native-position contracts used by current write operations.
local Remote=require('weread.lib.remote_progress')
local Source=require('weread.lib.source_remote_position')
local M={}
function M.state(raw,book,chapters,channel)
    assert(type(book)=='string' and #book>=4 and #book<=67 and book:match('^CB_[A-Za-z0-9]+$')
        and (channel=='web' or channel=='native'),'cb_cloud/scope')
    local p,reason=Source.resolve(raw,book,chapters,channel)
    if not p then return {kind=reason=='progress_no_chapter' and 'no_chapter' or 'unavailable',reason=reason} end
    local node=assert(Remote.node(raw,book))
    return {kind='located',book_id=book,chapter_uid=tostring(p.chapter_uid),chapter_idx=p.chapter_idx,chapter_offset=p.chapter_offset,
        raw_percent=p.raw_percent,summary=p.summary,index_source=p.chapter_index_source,summary_present=node.summary~=nil}
end
return M

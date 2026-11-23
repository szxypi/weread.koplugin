-- Save readable E-Ink chapters independently. A cancelled or failed batch
-- leaves completed chapters usable; a later batch verifies and skips them.
local Cache=require('weread.lib.native_direct_cache')
local Path=require('weread.lib.native_direct_path')
local Protocol=require('weread.lib.native_position_protocol')
local M={}

function M.run(client,settings,book,catalog,selected,current,progress)
    if type(book)~='table' or type(catalog)~='table' or catalog.book_id~=book.book_id
        or type(selected)~='table' or type(selected.scope)~='table'
        or type(current)~='function' or current()~=true or type(progress)~='function'
        or type(catalog.chapters)~='table' or #catalog.chapters<1 or #catalog.chapters>20000 then
        return {error='invalid'}
    end
    local rows=Cache.list(settings,selected.scope.vid,book.book_id,current)
    if not rows then return {error='storage'} end
    local by_chapter={}
    for _,entry in ipairs(rows) do
        if entry.book_version==catalog.version and entry.catalog_sha256==catalog.reading_digest then
            local group=by_chapter[entry.chapter_uid] or {};by_chapter[entry.chapter_uid]=group
            group[#group+1]=entry
        end
    end
    local result={ok=true,downloaded=0,saved=0,unavailable=0,missing=0}
    local total=#catalog.chapters
    for index,chapter in ipairs(catalog.chapters) do
        if current()~=true then return {error='session_changed'} end
        if not chapter.downloadable then result.unavailable=result.unavailable+1
        else
            local found
            for _,entry in ipairs(by_chapter[chapter.chapterUid] or {}) do
                if entry.catalog_order==index and entry.catalog_count==total
                    and entry.catalog_prev==chapter.catalog_prev and entry.catalog_next==chapter.catalog_next then
                    local verified=Cache.open(settings,selected.scope.vid,book.book_id,entry,current)
                    if verified then found=verified;break end
                end
            end
            if found then result.saved=result.saved+1
            else
                local room=Cache.remaining(settings,selected.scope.vid,book.book_id,current)
                if not room or room<1 then result.ok=false;result.error='storage';return result end
                local expected={book_id=book.book_id,chapter_uid=chapter.chapterUid,book_version=catalog.version,
                    reading_catalog_sha256=catalog.reading_digest,access_fingerprint=selected.fingerprint}
                local made,why=require('weread.lib.native_direct_reader').build(client,settings,book,chapter,expected,
                    {is_current=current,allow_missing_images=true})
                if not made then result.ok=false;result.error=why or 'unavailable';return result end
                if not Path.contains(settings,made.path) or made.book_version~=catalog.version
                    or not Protocol.integer(made.missing_images,0,64) then
                    result.ok=false;result.error='invalid';return result
                end
                found=made;result.downloaded=result.downloaded+1
            end
            if found.missing_images>0 then result.missing=result.missing+1 end
        end
        progress(math.min(99,math.floor(index*100/total)))
    end
    return result
end
return M

-- Save readable E-Ink chapters independently. A cancelled or failed batch
-- leaves completed chapters usable; a later batch verifies and skips them.
local Cache=require('weread.lib.native_direct_cache')
local Path=require('weread.lib.native_direct_path')
local Protocol=require('weread.lib.native_position_protocol')
local M={}

function M.run(client,settings,book,catalog,selected,current,progress,range)
    if type(book)~='table' or type(catalog)~='table' or catalog.book_id~=book.book_id
        or type(selected)~='table' or type(selected.scope)~='table'
        or type(current)~='function' or current()~=true or type(progress)~='function'
        or type(catalog.chapters)~='table' or #catalog.chapters<1 or #catalog.chapters>20000 then
        return {error='invalid'}
    end
    local total=#catalog.chapters
    if range~=nil and (type(range)~='table' or not Protocol.integer(range.first,1,total)
        or not Protocol.integer(range.last,range.first,total)) then return {error='invalid'} end
    local first,last,selection=1,total
    if range then
        first,last=range.first,range.last
        local chapters={}
        for index=first,last do
            local chapter=catalog.chapters[index]
            if chapter.downloadable then chapters[chapter.chapterUid]=true end
        end
        local uid=next(chapters)
        selection=chapters
        if uid and not next(chapters,uid) then selection=uid end
    end
    local rows=Cache.list(settings,selected.scope.vid,book.book_id,current,selection)
    if not rows then return {error='storage'} end
    local by_chapter={}
    for _,entry in ipairs(rows) do
        if entry.book_version==catalog.version and entry.catalog_sha256==catalog.reading_digest then
            local group=by_chapter[entry.chapter_uid] or {};by_chapter[entry.chapter_uid]=group
            group[#group+1]=entry
        end
    end
    local account=selected.scope.vid
    local capacity,scan_each_time
    local ok,value=pcall(function()
        local result={ok=true,downloaded=0,saved=0,unavailable=0,missing=0}
        for index=first,last do
            local chapter=catalog.chapters[index]
            if current()~=true then return {error='session_changed'} end
            if not chapter.downloadable then result.unavailable=result.unavailable+1
            else
                local found
                for _,entry in ipairs(by_chapter[chapter.chapterUid] or {}) do
                    if entry.catalog_order==index and entry.catalog_count==total
                        and entry.catalog_prev==chapter.catalog_prev and entry.catalog_next==chapter.catalog_next then
                        local verified=Cache.open(settings,account,book.book_id,entry,current)
                        if verified then found=verified;break end
                    end
                end
                if found then result.saved=result.saved+1
                else
                    if not capacity and not scan_each_time then
                        local reason
                        capacity,reason=Cache.begin_capacity(settings,account,book.book_id,current)
                        -- A new book gets its directory on its first save.
                        if reason=='unsupported' then scan_each_time=true
                        elseif not capacity and reason~='absent' then
                            result.ok=false;result.error='storage';return result
                        end
                    end
                    local room=Cache.remaining(settings,account,book.book_id,current,capacity)
                    if not room or room<1 then result.ok=false;result.error='storage';return result end
                    local expected={book_id=book.book_id,chapter_uid=chapter.chapterUid,book_version=catalog.version,
                        reading_catalog_sha256=catalog.reading_digest,access_fingerprint=selected.fingerprint}
                    local made,why=require('weread.lib.native_direct_reader').build(client,settings,book,chapter,expected,
                        {is_current=current,allow_missing_images=true,capacity=capacity})
                    if not made then result.ok=false;result.error=why or 'unavailable';return result end
                    if not Path.contains(settings,made.path) or made.book_version~=catalog.version
                        or not Protocol.integer(made.missing_images,0,64) then
                        result.ok=false;result.error='invalid';return result
                    end
                    found=made;result.downloaded=result.downloaded+1
                end
                if found.missing_images>0 then result.missing=result.missing+1 end
            end
            progress(math.min(99,math.floor((index-first+1)*100/(last-first+1))))
        end
        return result
    end)
    if capacity then capacity.lease:release() end
    if not ok then error(value,0) end
    return value
end
return M

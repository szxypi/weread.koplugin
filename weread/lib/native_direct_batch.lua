-- Save readable E-Ink chapters independently. A cancelled or failed batch
-- leaves completed chapters usable; a later batch verifies and skips them.
local Cache=require('weread.lib.native_direct_cache')
local Path=require('weread.lib.native_direct_path')
local Protocol=require('weread.lib.native_position_protocol')
local M={}

local function fewer_missing(a,b)
    return a.missing_images<b.missing_images
end

local function valid_job(book,catalog,selected,current,progress)
    return type(book)=='table' and type(catalog)=='table' and catalog.book_id==book.book_id
        and type(selected)=='table' and type(selected.scope)=='table'
        and type(current)=='function' and current()==true and type(progress)=='function'
        and type(catalog.chapters)=='table' and #catalog.chapters>=1 and #catalog.chapters<=20000
end

local function group_copies(rows,catalog,require_matching_index)
    local by_chapter={}
    local total=#catalog.chapters
    for _,entry in ipairs(rows) do
        local chapter=catalog.chapters[entry.catalog_order]
        if chapter and chapter.downloadable and chapter.chapterUid==entry.chapter_uid
            and entry.catalog_count==total and (not require_matching_index or entry.chapter_idx==chapter.chapterIdx)
            and entry.book_version==catalog.version and entry.catalog_sha256==catalog.reading_digest
            and entry.catalog_prev==chapter.catalog_prev and entry.catalog_next==chapter.catalog_next then
            local group=by_chapter[entry.chapter_uid] or {};by_chapter[entry.chapter_uid]=group
            group[#group+1]=entry
        end
    end
    return by_chapter
end

local function best_saved(settings,account,id,copies,current)
    if not copies then return end
    if #copies>1 then table.sort(copies,fewer_missing) end
    for _,entry in ipairs(copies) do
        local saved=Cache.open(settings,account,id,entry,current)
        if saved then return saved,entry end
    end
end

function M.run(client,settings,book,catalog,selected,current,progress,range)
    if not valid_job(book,catalog,selected,current,progress) then return {error='invalid'} end
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
    local by_chapter=group_copies(rows,catalog)
    local account=selected.scope.vid
    local capacity,scan_each_time
    local ok,value=pcall(function()
        local result={ok=true,downloaded=0,saved=0,unavailable=0,missing=0}
        for index=first,last do
            local chapter=catalog.chapters[index]
            if current()~=true then return {error='session_changed'} end
            if not chapter.downloadable then result.unavailable=result.unavailable+1
            else
                local found=best_saved(settings,account,book.book_id,by_chapter[chapter.chapterUid],current)
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

function M.repair(client,settings,book,catalog,selected,current,progress)
    if not valid_job(book,catalog,selected,current,progress) then return {error='invalid'} end
    local account,id=selected.scope.vid,book.book_id
    local rows=Cache.list(settings,account,id,current)
    if not rows then return {error='storage'} end
    local by_chapter=group_copies(rows,catalog,true)
    local targets,empty={},{}
    for _,chapter in ipairs(catalog.chapters) do
        for _,entry in ipairs(by_chapter[chapter.chapterUid] or empty) do
            if entry.missing_images>0 then
                targets[#targets+1]=chapter
                break
            end
        end
    end
    local capacity,scan_each_time
    local ok,value=pcall(function()
        local result={ok=true,improved=0,remaining=0,unverified=0}
        local refresh=require('weread.lib.native_direct_image_refresh')
        for index,chapter in ipairs(targets) do
            if current()~=true then return {error='session_changed'} end
            local saved,entry=best_saved(settings,account,id,by_chapter[chapter.chapterUid],current)
            if not saved then
                result.unverified=result.unverified+1
            elseif saved.missing_images>0 then
                local prepared,reason=refresh.prepare(client,settings,selected,entry,current)
                if prepared then
                    if not capacity and not scan_each_time then
                        capacity,reason=Cache.begin_capacity(settings,account,id,current)
                        if reason=='unsupported' then scan_each_time=true
                        elseif not capacity then return {error='storage'} end
                    end
                    local room=Cache.remaining(settings,account,id,current,capacity)
                    if not room or room<1 then return {error='storage'} end
                    local original=Cache.open(settings,account,id,entry,current)
                    if not original or original.file_id~=saved.file_id then return {error='changed'} end
                    local made,why=Cache.publish(settings,account,book,chapter,prepared,current,capacity)
                    if not made then return {error=why or 'storage'} end
                    result.improved=result.improved+1
                    if made.missing_images>0 then result.remaining=result.remaining+1 end
                elseif reason=='unchanged' then
                    result.remaining=result.remaining+1
                else
                    return {error=reason}
                end
            end
            progress(math.min(99,math.floor(index*100/#targets)))
        end
        return result
    end)
    if capacity then capacity.lease:release() end
    if not ok then error(value,0) end
    return value
end
return M

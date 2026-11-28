-- Reload chapter metadata immediately before a cross-file navigation.
local ReadAccess=require('weread.lib.read_access')
local M={}
function M.native_target(snapshot,direction)
    local ui=snapshot.ui
    local toc=ui.toc
    local method=direction<0 and 'getPreviousChapter' or 'getNextChapter'
    if type(toc)~='table' or type(toc[method])~='function' then return end
    local page=snapshot.page
    -- ReaderRolling considers both visible pages before jumping forward.
    if direction>0 and ui.rolling and snapshot.visible_pages>1 then page=page+1 end
    local ok,target=pcall(toc[method],toc,page)
    if ok and type(target)=='number' and target%1==0 and target>=1 and target<=snapshot.total
        and (target-page)*direction>0 then return target end
end

function M.move_native(snapshot,direction)
    snapshot.ui:handleEvent(require('ui/event'):new(direction<0 and 'GotoPrevChapter' or 'GotoNextChapter'))
end

local function id(row)
    if type(row)~='table' then return nil end
    local value=row.chapterUid or row.chapterId
    if type(value)~='string' and type(value)~='number' then return nil end
    if type(value)=='number' and (value~=value or value%1~=0 or math.abs(value)>9007199254740991) then return nil end
    value=tostring(value)
    return value~='' and value or nil
end
local function equal_field(a,b,key)
    if a[key]==nil or b[key]==nil then return a[key]==b[key] end
    return tostring(a[key])==tostring(b[key])
end

-- Match the EPUB's ordered chapters against the current catalog. Gaps from a
-- partial download are fine. Use the current viewport for an explicit chapter
-- switch, or the final spine member for KOReader's end-of-file event.
local function combined_index(book,document,proof,viewport)
    local catalog=book and book.chapters
    if not proof or type(proof.order)~='table' or type(proof.items)~='table'
        or type(catalog)~='table' or #catalog==0 or #catalog>20000 then return nil end
    local verified,opf=require('weread.lib.chapter_cache_claim').document_matches(proof,document,book.book_id or book.bookId)
    if not verified then return nil end
    local version=require('weread.lib.book_file_identity').version(book.bookVersion or book.book_version)
    if version>0 and (proof.book_version or 0)>0 and version~=proof.book_version then return nil end
    if document.getPageFlow and document:getPageFlow(document:getCurrentPage())~=0 then return nil end
    local origin=proof.order[#proof.order]
    if viewport then
        local location=require('weread.lib.source_context').location(document,viewport.mode)
        if not location then return nil end
        if viewport.mode=='scroll' then
            local view=viewport.ui.view
            local height=view and view.dimen and view.dimen.h
            if not require('weread.lib.reader_position').contains_anchor(document,
                {view_mode='scroll',pos=location.pos,viewport_height=height},location.xpointer) then return nil end
        end
        local Dom=require('weread.lib.source_dom')
        local member=Dom.member(document,location.xpointer)
        origin=member and Dom.chapter_member(opf,member.render_path)
        if not origin or not proof.items[origin] then return nil end
    end
    local seen,matched,selected,count={},0,nil,0
    for index,row in ipairs(catalog) do
        local uid=id(row)
        if not uid or seen[uid] then return nil end
        seen[uid]=true;count=index
        local member='chapter_'..uid
        if proof.items[member] then
            matched=matched+1
            if proof.order[matched]~=member then return nil end
            if origin==member then selected=index end
        end
    end
    if count==#catalog and matched==#proof.order then return selected end
end

function M.combined_end(book,document,proof)
    return combined_index(book,document,proof)
end

function M.combined_current(book,viewport,proof)
    if viewport then return combined_index(book,viewport.document,proof,viewport) end
end

function M.resolve(host,expected,direction)
    if not host or type(expected)~='table' or type(expected.book)~='table'
        or type(expected.book_id)~='string' or type(expected.index)~='number'
        or expected.index%1~=0 or expected.index<1 or (direction~=-1 and direction~=1)
        or not host.settings or type(host.settings.get_book)~='function'
        or type(host.getChapterInfoFromFile)~='function' then return nil end
    local book=ReadAccess.load_cached_book(host.settings,expected.book_id)
    if not book or book.book_id==nil and book.bookId==nil then return nil end
    for _,key in ipairs({'bookVersion','book_version','version','fileId','file_id','cache_dir'}) do
        if not equal_field(book,expected.book,key) then return nil end
    end
    local catalog=book.chapters
    if type(catalog)~='table' or #catalog==0 then
        catalog=require('weread.lib.content').load_catalog_cache(host.client,host.settings,book)
    end
    if type(catalog)~='table' or #catalog==0 then
        local db=host.library_db
        catalog=db and type(db.getChapters)=='function' and db:getChapters(expected.book_id) or nil
    end
    if type(catalog)~='table' or #catalog==0 then return nil end
    book.chapters=catalog
    local index,current,combined,partial,proof=host:getChapterInfoFromFile(book,expected.file)
    if expected.combined_file then
        local document=host.ui and host.ui.document
        if not document or document.file~=expected.file or not combined or not partial
            or not proof or proof.file_id~=expected.combined_file
            or proof.opf_hash~=expected.combined_opf then return nil end
        if expected.from_viewport then
            index=M.combined_current(book,require('weread.lib.reader_progress_context').capture(host),proof)
        elseif direction==1 then
            index=M.combined_end(book,document,proof)
        else
            return nil
        end
        current=index and catalog[index]
    elseif combined then
        return nil
    end
    if index~=expected.index or id(current)~=expected.current
        or id(catalog[index-1])~=expected.previous or id(catalog[index+1])~=expected.next then return nil end
    local target=catalog[index+direction]
    local current_id,target_id=id(current),id(target)
    if not current_id or not target_id or target_id==current_id then return nil end
    if expected.combined_file then return book,target end
    local current_count,target_count=0,0
    for _,row in ipairs(catalog) do
        local uid=id(row)
        if uid==current_id then current_count=current_count+1 end
        if uid==target_id then target_count=target_count+1 end
    end
    if current_count~=1 or target_count~=1 then return nil end
    return book,target
end
return M

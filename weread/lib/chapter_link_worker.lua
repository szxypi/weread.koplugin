-- Independent archive reads for standalone chapter links. No native document
-- handles, networking, UI state, or credential objects enter this worker.
local Archive=require('weread.lib.source_archive')
local Identity=require('weread.lib.book_file_identity')
local Footnotes=require('weread.lib.footnotes')
local Links=require('weread.lib.book_link_paths')
local Crypto=require('weread.lib.crypto')
local M={RENDER_PATH='OEBPS/text/chapter.xhtml',MAX_CATALOG=10000}
local function text(value,maximum)
    return type(value)=='string' and #value>0 and #value<=maximum and not value:find('[%z%c]')
end
local function hash(value) return type(value)=='string' and #value==64 and value:match('^[a-f0-9]+$')~=nil end
local function uid(chapter) return type(chapter)=='table' and tostring(chapter.chapterUid or chapter.uid or '') or '' end
local function failure(reason) return {kind='unavailable',reason=reason} end
local function read(path,book_id,chapter_uid,expected,reader)
    if not text(path,4096) then return nil,'file_unavailable' end
    local members=(reader or Archive.read)(path,{[Identity.PATH]=Identity.MAX_BYTES,
        ['OEBPS/content.opf']=1024*1024,[M.RENDER_PATH]=Archive.MAX_MEMBER_BYTES})
    if not members then return nil,'file_unavailable' end
    local identity=Identity.decode(members[Identity.PATH])
    if not identity or identity.book_id~=book_id or identity.chapter_count~=1
        or expected and identity.file_id~=expected then return nil,'file_changed' end
    local count,identifier=0,nil
    for _i,value in ipairs(Footnotes.element_texts(members['OEBPS/content.opf'],'dc:identifier')) do
        count=count+1;identifier=Links.attribute(value.text)
    end
    if count~=1 or identifier~='weread-' .. book_id .. '-' .. chapter_uid then return nil,'chapter_mismatch' end
    return {identity=identity,html=members[M.RENDER_PATH],sha256=Crypto.sha256_hex(members[M.RENDER_PATH])}
end
function M.prepare(input,reader)
    if type(input)~='table' or not text(input.book_id,256) or not text(input.chapter_uid,256)
        or not text(input.file,4096) or not hash(input.file_id) or not text(input.native_uri,8192)
        or type(input.chapters)~='table' or #input.chapters==0 or #input.chapters>M.MAX_CATALOG
        or type(input.cached_chapters)~='table' then return failure('input_invalid') end
    local chapters,seen,current={},{},nil
    local catalog_count=0
    for key in pairs(input.chapters) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#input.chapters then return failure('catalog_invalid') end
        catalog_count=catalog_count+1
    end
    if catalog_count~=#input.chapters then return failure('catalog_invalid') end
    for index,chapter in ipairs(input.chapters) do
        local key=uid(chapter)
        if not text(key,256) or seen[key] then return failure('catalog_ambiguous') end
        if chapter.files~=nil and type(chapter.files)~='table' then return failure('catalog_invalid') end
        seen[key]=true;chapters[index]=chapter
        if key==input.chapter_uid then current=chapter end
    end
    if not current or input.cached_chapters[input.chapter_uid]~=input.file then return failure('source_unavailable') end
    local source,reason=read(input.file,input.book_id,input.chapter_uid,input.file_id,reader)
    if not source then return failure(reason) end
    local native=Links.native_uri_key(M.RENDER_PATH,input.native_uri)
    if not native then return failure('link_unsupported') end
    local scans={}
    for _i,chapter in ipairs(chapters) do
        local key=uid(chapter)
        scans[key]={chapter=chapter,anchors={},anchors_unknown=true}
    end
    local scan=Footnotes.scan_links(source.html,current)
    scans[input.chapter_uid]=scan
    local index=Links.build(scans,chapters)
    local planned,matched
    for _i,href in ipairs(scan.link_hrefs) do
        if Links.rebased_href(M.RENDER_PATH,href)==native then
            matched=true
            local candidate=Links.plan(index,input.chapter_uid,href)
            if not candidate or candidate.uid==input.chapter_uid then return failure('link_unavailable') end
            if planned and (planned.uid~=candidate.uid or planned.anchor~=candidate.anchor) then return failure('link_ambiguous') end
            planned=candidate
        end
    end
    if not matched or not planned then return failure('link_unavailable') end
    local result={kind='needs_download',book_id=input.book_id,source_uid=input.chapter_uid,
        source_file_id=source.identity.file_id,source_sha256=source.sha256,
        target_uid=planned.uid,anchor=planned.anchor,anchor_verified=false}
    local path=input.cached_chapters[planned.uid]
    if not text(path,4096) then return result end
    local target,target_reason=read(path,input.book_id,planned.uid,nil,reader)
    if not target then result.reason=target_reason;return result end
    if source.identity.book_version>0 and target.identity.book_version>0
        and source.identity.book_version~=target.identity.book_version then return failure('version_mismatch') end
    local target_scan=Footnotes.scan_links(target.html,{chapterUid=planned.uid})
    if planned.anchor and planned.anchor~='' then
        local count=0
        for anchor,number in pairs(target_scan.anchor_counts) do
            if Links.attribute(anchor)==planned.anchor then count=count+number end
        end
        if count~=1 then return failure(count==0 and 'anchor_missing' or 'anchor_ambiguous') end
    end
    result.kind,result.target_path,result.target_file_id='ready',path,target.identity.file_id
    result.target_sha256,result.anchor_verified=target.sha256,true
    return result
end
M.read=read
return M

-- Private source is stdin-only; emit fixed counters, never IDs, paths or text.
local repo=assert(arg[1])
require('ffi').log=function() end
require('setupkoenv')
package.path=repo .. '/?.lua;' .. package.path
local json=require('json')
local Logging=require('weread.lib.logger')
local original_scoped=Logging.scoped
Logging.scoped=function(label)
    if label=='Footnotes' then return setmetatable({},{__index=function() return function() end end}) end
    return original_scoped(label)
end
local Footnotes=require('weread.lib.footnotes')
local Links=require('weread.lib.book_link_paths')
local raw=io.read(32*1024*1024+1)
assert(#raw<=32*1024*1024,'input_limit')
local input=json.decode(raw)
assert(type(input)=='table' and type(input.chapters)=='table' and type(input.samples)=='table','input_invalid')
local scans={}
local result={result='PASS',catalog_chapters=#input.chapters,sampled_chapters=#input.samples,anchors=0,links=0,
    same_chapter_ready=0,cross_chapter_ready=0,cross_chapter_plans=0,external_links=0,unresolved_links=0,chapters_with_file_metadata=0,image_notes=0,converted_notes=0,conversion_fallbacks=0,valid_converted_chapters=0,native_opened_chapters=0,native_popup_checks=0,native_jump_checks=0,native_back_checks=0,native_error_code=0,native_failure_stage=0,native_plugin_checks=0,native_expected_bytes=0,native_actual_bytes=0,native_expected_nbsp=0,native_expected_zwsp=0,native_expected_zwnj=0,native_expected_zwj=0,converted_text_matches=0,native_actual_nbsp=0,native_whitespace_normalizations=0,native_actual_soft_hyphens=0,native_expected_soft_hyphens=0,native_hyphenation_normalizations=0,chapters_with_resolved_paths=0,source_path_aliases=0,shared_source_paths=0}
for _i,chapter in ipairs(input.chapters) do
    local uid=tostring(chapter.chapterUid)
    scans[uid]={chapter=chapter,anchors={},anchors_unknown=true}
    if #(chapter.files or {})>0 or chapter.href or chapter.file or chapter.filename or chapter.fileName or chapter.path or chapter.chapterPath then
        result.chapters_with_file_metadata=result.chapters_with_file_metadata+1
    end
end
for _i,sample in ipairs(input.samples) do
    local uid=tostring(sample.uid)
    assert(scans[uid] and type(sample.html)=='string','sample_invalid')
    scans[uid]=Footnotes.scan_links(sample.html,scans[uid].chapter)
    for _anchor,count in pairs(scans[uid].anchor_counts) do result.anchors=result.anchors+count end
end
local index=Links.build(scans,input.chapters)
for _uid,entry in pairs(index.entries) do
    if entry.physical then result.chapters_with_resolved_paths=result.chapters_with_resolved_paths+1 end
    result.source_path_aliases=result.source_path_aliases+#entry.paths
end
for _path,owners in pairs(index.files) do
    local count=0;for _uid in pairs(owners) do count=count+1 end
    if count>1 then result.shared_source_paths=result.shared_source_paths+1 end
end
for _i,sample in ipairs(input.samples) do
    local uid=tostring(sample.uid)
    for _j,href in ipairs(scans[uid].link_hrefs) do
        result.links=result.links+1
        local target,reason=Links.plan(index,uid,href)
        if target then
            local key=target.uid==uid and 'same_chapter_ready' or target.anchor_verified and 'cross_chapter_ready' or 'cross_chapter_plans'
            result[key]=result[key]+1
        else
            local key=reason=='external' and 'external_links' or 'unresolved_links';result[key]=result[key]+1
        end
    end
end
local complete={}
for _i,sample in ipairs(input.samples) do
    local uid=tostring(sample.uid);complete[uid]=Footnotes.scan_chapter(sample.html,scans[uid].chapter)
end
local conversion=Footnotes.build_book_index(complete,input.chapters)
local rendered={}
for _i,sample in ipairs(input.samples) do
    local out,stats=Footnotes.transform_chapter(sample.html,complete[tostring(sample.uid)],conversion)
    local plain=Links.attribute(out:gsub('<[^>]*>','')):gsub('%s','')
    for _j,expected in ipairs(sample.expected_notes or {}) do
        if plain:find(expected:gsub('%s',''),1,true) then result.converted_text_matches=result.converted_text_matches+1 end
    end
    rendered[#rendered+1]={html=out,chapter=complete[tostring(sample.uid)].chapter,expected=sample.expected_notes or {}}
    result.image_notes=result.image_notes+(stats.image_notes or 0)
    result.converted_notes=result.converted_notes+(stats.converted or 0)
    result.conversion_fallbacks=result.conversion_fallbacks+(stats.fallback or 0)
    if Footnotes.validate(out) then result.valid_converted_chapters=result.valid_converted_chapters+1 end
end
if arg[2]=='native' then
    local ok=pcall(function() assert(loadfile(assert(os.getenv('WEREAD_NOTE_CASE'))))()(rendered,result) end)
    if not ok then result.native_error_code=99 end
end
print('\nWEREAD_OWNER_FOOTNOTE_LINK_RESULT=' .. json.encode(result))

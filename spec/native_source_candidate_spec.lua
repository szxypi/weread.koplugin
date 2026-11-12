package.path='./?.lua;'..package.path
local C=require('weread.lib.native_source_candidate')
local Map=require('weread.lib.source_coordinates')
local checks=0
local function expect(v,why) checks=checks+1;assert(v,why or ('check '..checks)) end
local function copy(v) if type(v)~='table' then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local raw='A😀\r\n　 <tag>&amp;é末尾LiteralRawSummary'
local packet={position={book_id='900001',chapter_uid='11',chapter_offset=1,file_id=string.rep('a',64),
    book_version=7,raw_sha256=string.rep('b',64),render_path='OEBPS/text/chapter.xhtml',basis='raw_txt_utf16',upload_verified=false},
    excerpt=assert(Map.build(raw,{format='web_txt'})):literal_excerpt(1)}
local chapters={{chapterUid=11,chapterIdx=0}}
local p=assert(C.project(packet,chapters,37))
expect(p.chapter_idx==0 and p.raw_percent==37 and p.chapter_offset==1 and p.summary==packet.excerpt.text)
expect(p.basis=='raw_txt_utf16' and p.upload_verified==false and not p.version,'local archive version became an API version')
expect(not packet.position.summary and not packet.position.chapter_idx,'projection mutated a local checkpoint')
for _i,value in ipairs({-1,101,37.5,'37',true,0/0,math.huge}) do expect(not C.project(packet,chapters,value),'invalid viewport percent') end
for _i,change in ipairs({{basis='filtered_xhtml_utf16'},{upload_verified=true},{file_id='bad'},{book_version=true},
    {chapter_uid='9007199254740992'},{book_id=900001},{render_path='../other.xhtml'},{extra='private'}}) do
    local v=copy(packet);for k,x in pairs(change) do v.position[k]=x end
    expect(not C.project(v,chapters,37),'invalid source projection')
end
for _i,change in ipairs({{text='A\0B'},{text='\237\160\128'},{text=string.rep('a',31)},
    {co=2},{end_co=1},{scalars=true},{basis='filtered_xhtml_utf16'},{upload_verified=true},{raw='private'}}) do
    local v=copy(packet);for k,x in pairs(change) do v.excerpt[k]=x end
    expect(not C.project(v,chapters,37),'invalid raw excerpt projection')
end
for _i,catalog in ipairs({{},{{chapterUid=11}},{{chapterUid=11,chapterIdx=true}},{{chapterUid=11,chapterIdx=1,chapter_idx=2}},
    {{chapterUid=11,chapterIdx=0},{chapterUid=11,chapterIdx=0}}}) do expect(not C.project(packet,catalog,37),'ambiguous UID/index') end
local extra=copy(packet);extra.summary='private';expect(not C.project(extra,chapters,37))
print(('native_source_candidate_spec: %d checks'):format(checks))

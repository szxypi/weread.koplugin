package.path='./?.lua;' .. package.path
package.preload['logger']=function() return {info=function() end,warn=function() end,dbg=function() end,err=function() end} end
local F=require('weread.lib.footnotes')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local chapters={{chapterUid=1,files={'Text/body.xhtml'}},{chapterUid=2,files={'Text/notes.xhtml'}},
    {chapterUid=3,files={'Text/references.xhtml'}}}
local originals={
    '<p>正文<a id="source-ref" epub:type="noteref" href="notes.xhtml#remote-rich">[1]</a></p>',
    '<aside epub:type="footnote" id="remote-rich">图注<img src="note.svg"/>'
        .. '<a role="doc-backlink" href="body.xhtml#source-ref">返回正文</a>'
        .. '<a href="references.xhtml#source-ref">查看资料</a>'
        .. '<a href="body.xhtml#source-ref">[1]</a></aside><p id="source-ref">本章同名锚点</p>',
    '<p id="source-ref">真正的资料位置<a href="notes.xhtml#remote-rich">返回注释</a></p>',
}
local scans,hrefs={},{}
for index,chapter in ipairs(chapters) do
    scans[tostring(chapter.chapterUid)]=F.scan_chapter(originals[index],chapter)
    hrefs[tostring(chapter.chapterUid)]=string.format('chapter-%03d.xhtml',index)
end
local book=F.build_book_index(scans,chapters,hrefs)
local bodies={}
for index,chapter in ipairs(chapters) do bodies[index]=F.transform_chapter(originals[index],scans[tostring(chapter.chapterUid)],book) end
expect(bodies[2]:find('href="chapter-001.xhtml#source-ref"',1,true), 'original cross-chapter backlink was not remapped')
expect(bodies[2]:find('href="chapter-003.xhtml#source-ref"',1,true), 'ordinary citation was not remapped')
expect(not bodies[2]:find('href="#source-ref"',1,true), 'foreign backlink chose a same-name local anchor')
expect(bodies[3]:find('href="chapter-002.xhtml#remote-rich"',1,true), 'second-hop return was not remapped')
expect(bodies[1]:find('href="chapter-002.xhtml#remote-rich"',1,true), 'original rich note link regressed')
expect(bodies[2]:find('<img src="note.svg"/>',1,true), 'note media changed')
local P=require('weread.lib.book_link_paths')
local function fixture(descriptions,outputs)
    local entries,metadata={},{ }
    for index,description in ipairs(descriptions) do
        local chapter={chapterUid=index,files=description.paths,chapterIdx=description.idx}
        if description.href then chapter.href=description.href end
        metadata[index]=chapter
        entries[tostring(index)]={chapter=chapter,anchors=description.anchors or {},
            anchor_counts=description.counts,forward_ref_ids=description.forward or {}}
    end
    local targets={}
    for index in ipairs(descriptions) do targets[tostring(index)]=string.format('chapter-%03d.xhtml',index) end
    return P.build(entries,metadata,outputs or targets),entries,metadata
end
local function resolves(index,from,href,wanted,label)
    local result=P.resolve(index,from,href)
    expect(result and result.href==wanted,label or href)
end
local function unchanged(index,from,href,label)
    local result=P.resolve(index,from,href)
    expect(not result,label or href)
end
local paths=fixture({{paths={'Text/Body.xhtml'},anchors={ref=true},forward={ref=true}},
    {paths={'Text/Notes.xhtml'},anchors={note=true}},
    {paths={'Other/Notes.xhtml'},anchors={other=true}}})
resolves(paths,1,'Notes.xhtml#note','chapter-002.xhtml#note','relative path is case-sensitive')
resolves(paths,1,'../Other/Notes.xhtml#other','chapter-003.xhtml#other')
resolves(paths,2,'Body.xhtml#ref','chapter-001.xhtml#ref')
expect(P.resolve(paths,2,'Body.xhtml#ref').forward_ref, 'original reference identity retained')
resolves(paths,1,'Notes.xhtml','chapter-002.xhtml','file-only citation resolves to chapter top')
resolves(paths,1,'/Other/Notes.xhtml#other','chapter-003.xhtml#other')
resolves(paths,1,'Other/Notes.xhtml#other','chapter-003.xhtml#other','complete metadata archive alias supported')
resolves(paths,1,'../Text/./Notes.xhtml#note','chapter-002.xhtml#note')
resolves(paths,1,'..\\Other\\Notes.xhtml#other','chapter-003.xhtml#other')
for _i,value in ipairs({'notes.xhtml#note','Unknown/Notes.xhtml#note','Notes.xhtml#other',
    'Notes.xhtml#missing','Notes.xhtml?version=1#note','../../Notes.xhtml#note',
    'https://example.org/Text/Notes.xhtml#note','//example.org/Text/Notes.xhtml#note',
    'mailto:reader@example.org#note','data:text/html#note','file:///Text/Notes.xhtml#note',
    'javascript:note#note','Notes.xhtml#%00','Notes.xhtml#bad%zz'}) do unchanged(paths,1,value) end
resolves(paths,1,'#ref','#ref','local anchors retain their file scope')
local duplicate=fixture({{paths={'Text/body.xhtml'},anchors={n=true}},
    {paths={'Text/notes.xhtml'},counts={n=2}}})
unchanged(duplicate,1,'notes.xhtml#n','duplicate IDs never choose a target')
local split=fixture({{paths={'Text/shared.xhtml'},anchors={start=true}},
    {paths={'Text/shared.xhtml'},anchors={note=true}},
    {paths={'Text/other.xhtml'},anchors={start=true}}})
resolves(split,1,'#note','chapter-002.xhtml#note','same original file split among catalog entries')
resolves(split,3,'shared.xhtml#note','chapter-002.xhtml#note')
unchanged(split,3,'shared.xhtml','shared file without a fragment is ambiguous')
local same=fixture({{paths={'Text/shared.xhtml'},anchors={n=true}},
    {paths={'Text/shared.xhtml'},anchors={n=true}}})
unchanged(same,1,'shared.xhtml#n','equal IDs in split original file remain ambiguous')
local multi=fixture({{paths={'A/body.xhtml','B/body.xhtml'},anchors={ref=true}},
    {paths={'A/notes.xhtml'},anchors={n=true}},{paths={'B/notes.xhtml'},anchors={n=true}}})
unchanged(multi,1,'notes.xhtml#n','ambiguous original source fragment is not guessed')
local partial=fixture({{paths={'A/body.xhtml','B/body.xhtml'},anchors={ref=true}},
    {paths={'A/notes.xhtml'},anchors={n=true}}})
unchanged(partial,1,'notes.xhtml#n','one unknown source location is not silently discarded')
local opaque=fixture({{anchors={ref=true}},{paths={'A/notes.xhtml'},anchors={n=true}},
    {paths={'B/notes.xhtml'},anchors={other=true}}})
unchanged(opaque,1,'notes.xhtml#n','basename ambiguity is checked before anchor uniqueness')
local unique=fixture({{anchors={ref=true}},{paths={'A/notes.xhtml'},anchors={n=true}}})
resolves(unique,1,'notes.xhtml#n','chapter-002.xhtml#n','unique metadata basename for unknown source path')
local encoded=fixture({{paths={'Text/body.xhtml'},anchors={ref=true}},
    {paths={'Text/资料 100%.xhtml'},counts={['条目&amp;引文']=1,['&#x4E2D;文']=1,['literal%2A']=1}}})
resolves(encoded,1,'%E8%B5%84%E6%96%99%20100%25.xhtml#%E6%9D%A1%E7%9B%AE%26%E5%BC%95%E6%96%87',
    'chapter-002.xhtml#%E6%9D%A1%E7%9B%AE%26%E5%BC%95%E6%96%87','Unicode path, literal percent and XML entity ID')
resolves(encoded,1,'资料%20100%25.xhtml#中文','chapter-002.xhtml#%E4%B8%AD%E6%96%87','numeric XML entity ID')
resolves(encoded,1,'资料%20100%25.xhtml#literal%252A','chapter-002.xhtml#literal%252A','percent decoded once')
local punctuation=fixture({{paths={'Text/body.xhtml'},anchors={ref=true}},
    {paths={'Text/notes?#.xhtml'},anchors={n=true}}})
resolves(punctuation,1,'notes%3F%23.xhtml#n','chapter-002.xhtml#n','encoded query/hash are filename characters')
expect(P.attribute('&amp;lt;')=='&lt;' and P.attribute('&#39;&apos;')=="''", 'XML attributes decoded once')
local absent=fixture({{paths={'Text/body.xhtml'},anchors={ref=true}},
    {paths={'Text/notes.xhtml'},anchors={n=true}}},{['1']='chapter-001.xhtml'})
unchanged(absent,1,'notes.xhtml#n','independent EPUB never invents a foreign member')
local bad=fixture({{paths={'Text/body.xhtml'},anchors={ref=true}},
    {paths={'Text/notes.xhtml'},anchors={n=true}}},{['1']='chapter-001.xhtml',['2']='../../notes.xhtml'})
unchanged(bad,1,'notes.xhtml#n','output must be a generated chapter member')
local reused=fixture({{paths={'Text/body.xhtml'},anchors={ref=true}},
    {paths={'Text/notes.xhtml'},anchors={n=true}}},{['1']='chapter-001.xhtml',['2']='chapter-001.xhtml'})
unchanged(reused,1,'notes.xhtml#n','duplicate packaged output is not accepted')

-- Non-footnote citations, external links and same-name foreign references all
-- go through the actual HTML transformer, not only the path model.
local entity='<p><a HREF="unused">ignore</a><a href=\'references.xhtml#source-ref\' title="a > b">资料</a>'
    .. '<a epub:type="noteref" href="https://example.org/notes.xhtml#remote-rich">[9]</a>'
    .. '<a epub:type="noteref" href="unknown.xhtml#source-ref">[8]</a></p>'
local entity_scan=F.scan_chapter(entity,chapters[1])
local entity_index=F.build_book_index({['1']=entity_scan,['2']=scans['2'],['3']=scans['3']},chapters,hrefs)
local entity_body=F.transform_chapter(entity,entity_scan,entity_index)
expect(entity_body:find("href='chapter-003.xhtml#source-ref' title=\"a > b\"",1,true),'single quote and quoted greater-than retained')
expect(entity_body:find('href="https://example.org/notes.xhtml#remote-rich"',1,true),'external noteref not localized')
expect(entity_body:find('href="unknown.xhtml#source-ref"',1,true),'unknown file not localized through a unique/local ID')
local span='<p>正文<a epub:type="noteref" href="references.xhtml#only-anchor">[7]</a></p>'
local span_scan=F.scan_chapter(span,chapters[1])
local target_scan=F.scan_chapter('<span id="only-anchor"/>',chapters[3])
local span_body,span_stats=F.transform_chapter(span,span_scan,
    F.build_book_index({['1']=span_scan,['3']=target_scan},{chapters[1],chapters[3]},hrefs))
expect(span_body:find('href="chapter-003.xhtml#only-anchor"',1,true) and span_stats.unresolved==0,
    'known non-note anchor is linked without being falsely marked unresolved')
local known={['#_doc_fragment_2_ 材料&说明']=true,['#literal%2A']=true}
local document={isXPointerInDocument=function(_self,value) return known[value] or false end}
expect(P.native_xpointer(document,'#_doc_fragment_2_ %E6%9D%90%E6%96%99%26%E8%AF%B4%E6%98%8E')=='#_doc_fragment_2_ 材料&说明',
    'encoded native fragment normalized to existing DOM anchor')
expect(P.native_xpointer(document,'#literal%252A')=='#literal%2A','native fragment decoded exactly once')
for _i,value in ipairs({'/body/p[1]/text().2','https://example.org#%E4%B8%AD','#missing%20anchor','#bad%zz','#bad%00'}) do
    expect(P.native_xpointer(document,value)==value,'unproven or non-fragment position unchanged')
end
expect(P.native_xpointer({isXPointerInDocument=function() error('closed document') end},'#encoded%20id')=='#encoded%20id',
    'unavailable DOM leaves normal navigation intact')
print('footnote_paths_spec: ' .. checks .. ' checks passed')

package.path='./?.lua;'..package.path
local Dom=require('weread.lib.source_dom')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Coordinates=require('weread.lib.source_coordinates')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,message) checks=checks+1; assert(value,message or ('check '..checks)) end
local function chars(text)
    local out={}
    for character in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do out[#out+1]=character end
    return out
end
local function fixture(raw,text,options)
    options=options or {}
    local book,chapter={book_id='synthetic-dom',bookVersion=7},{chapterUid=11}
    local render='<html><body>'..text..'</body></html>'
    local root='/body/DocFragment[1]'
    local path='OEBPS/text/chapter-001.xhtml'
    local source=assert(Source.capture(book,chapter,raw,options.format or 'web_xhtml'))
    local identity=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(render))
    local meta=assert(Source.bind(source,assert(Identity.decode(identity)),path,Crypto.sha256_hex(render)))
    local archive={ [Identity.PATH]=identity,[Source.meta_path(11)]=meta,[path]=render,
        [Source.raw_path(source.raw_sha256)]=raw,
        ['OEBPS/content.opf']='<package><manifest><item id="c" href="text/chapter-001.xhtml"/></manifest><spine><itemref idref="c"/></spine></package>' }
    local physical,starts={},{}
    local at=1
    for _,character in ipairs(chars(text)) do
        if character~='\n' and character~='\r' then
            starts[#starts+1]=at
            physical[#physical+1]=character
        end
        at=at+#character
    end
    starts[#starts+1]=#text+1
    local node=table.concat(physical)
    local function xp(n) return root..'/body/p/text().'..n end
    local function offset(point)
        if point==root..'.0' then return 0 end
        if type(point)~='string' or point:sub(1,#root)~=root then error('private fixture diagnostic') end
        return assert(tonumber(point:match('%.(%d+)$')))
    end
    local counters={search=0,move=0,clear=0}
    local doc={been_rendered=true}
    function doc:getDocumentFileContent(name) return archive[name] end
    function doc:getNormalizedXPointer(point) return point end
    function doc:getHTMLFromXPointer() return '<DocFragment Source="'..(options.source_path or path)..'"><body/></DocFragment>' end
    function doc:getTextFromXPointer() return node end
    function doc:getTextFromXPointers(first,last)
        return text:sub(starts[offset(first)+1],starts[offset(last)+1]-1)
    end
    function doc:getPageCount() return 1 end
    function doc:getPageXPointer() return xp(math.max(0,#physical-2)) end
    function doc:getNextVisibleChar(point) return offset(point)<#physical and xp(offset(point)+1) or nil end
    function doc:getPrevVisibleChar(point)
        local value=offset(point)
        return value>0 and xp(value-1) or nil
    end
    function doc:clearSelection() counters.clear=counters.clear+1 end
    function doc:findAllText() counters.search=counters.search+1; error('whole-book search called') end
    function doc:gotoXPointer() counters.move=counters.move+1; error('navigation called') end
    local index,err=Dom.open(doc,book.book_id,11,options)
    return index,err,doc,archive,counters,xp
end
local sample='ABCDE😀&中文[36]FGHIJKLMNOPQRSTUVWXYZ'
local spaced='AB CD\tE😀\194\160&中文[36]\227\128\128FGHIJ\r\nKLMNOPQRSTUVWXYZ'
expect(Dom.normalize(spaced)==sample,'source/DOM whitespace policy differs')
expect(Dom.normalize('\239\187\191[36]')=='\239\187\191[36]','annotation cleanup moved literal text')
for _,invalid in ipairs({'\255','\192\128','\237\160\128','\244\144\128\128',string.rep('x',Dom.MAX_TEXT_BYTES+1)}) do
    local result,err=Dom.normalize(invalid)
    expect(not result and err:match('^source_dom/'),'invalid/oversized text accepted')
end
for _,space in ipairs({'\194\133','\225\154\128','\226\128\128','\226\128\138','\226\128\168',
    '\226\128\169','\226\128\175','\226\129\159','\227\128\128'}) do
    local plain='abcdefghijklm'..space..'nopqrstuvwxyz'
    expect(Dom.normalize(plain)==assert(Coordinates.build('<body><p>'..plain..'</p></body>')).flat,
        'normalization diverged from source coordinate schema')
end
local raw='<html><body><p>跨段起点的第一句话足够长而且内容不同。</p><p>跨段目标的第二句话用于验证精确位置。</p><p>原始[36]与A&amp;B和😀保持不变。</p></body></html>'
local text='跨段起点的第一句话足够长而且内容不同。\n跨段目标的第二句话用于验证精确位置。\n原始[36]与A&B和😀保持不变。'
local index,err,doc,archive,counters,xp=fixture(raw,text)
expect(index,err)
local map=assert(Coordinates.build(raw))
local point=assert(map:locate('跨段目标的第二句话用于验证精确位置。'))
local located,reason=index:locate(point.co)
expect(located,reason)
expect(assert(index:capture(located.xpointer)).co==point.co,'cross-block roundtrip changed source co')
expect(counters.search==0 and counters.move==0 and counters.clear>0,'mapping searched book, navigated, or left selection')
expect(not index:capture('/body/DocFragment[2]/body/p/text().0'),'other chapter accepted')
expect(not index:capture('/body/DocFragment[1]/body/p.0'),'element pointer accepted as scalar position')
expect(not index:locate(-1),'invalid source offset accepted')
expect(not index:capture(xp(999999)),'native text offset outside scalar bounds accepted')
local end_co=assert(map:locate('原始[36]与A&B和😀保持不变。')).end_co
expect(index:locate(end_co),'chapter end boundary unavailable')
local before=index.stats.checkpoints
for _i=1,100 do assert(index:locate(point.co),'repeat lookup lost endpoint') end
expect(index.stats.checkpoints==before,'repeat queries retained extra pointers')
local duplicate=assert(fixture(raw,text..'\n'..text))
local duplicate_point,duplicate_reason=duplicate:locate(point.co)
expect(not duplicate_point and duplicate_reason=='source_dom/anchor_ambiguous','duplicate local text was guessed')
local throwing,throw_error=fixture(raw,text,{is_current=function() error('private callback diagnostic') end})
expect(not throwing and throw_error=='source_dom/cancelled','failed scope guard was trusted')
local _,_,failing_doc=fixture(raw,text)
failing_doc.getHTMLFromXPointer=function() error('private DOM diagnostic') end
local failure,failure_reason=Dom.open(failing_doc,'synthetic-dom',11)
expect(not failure and failure_reason=='source_dom/native_failure','native diagnostic leaked')
local unsupported,unsupported_reason=fixture('plain text original',text,{format='web_txt'})
expect(not unsupported and unsupported_reason=='source_dom/format_unsupported','TXT activated as XHTML coordinates')
local changed,changed_err,changed_doc,changed_archive=fixture(raw,text)
expect(changed,changed_err)
local old_identity=changed_archive[Identity.PATH]
changed_archive[Identity.PATH]=Identity.encode({book_id='synthetic-dom',bookVersion=8},{{chapterUid=11}},
    {book_id='synthetic-dom',book_version=8},Crypto.sha256_hex('replacement'))
Identity.forget(changed_doc)
local rebound,rebound_reason=changed:capture(located.xpointer)
expect(not rebound and rebound_reason=='source_dom/file_changed','changed file reused source index')
changed_archive[Identity.PATH]=old_identity
Identity.forget(changed_doc)
expect(not changed:capture(located.xpointer),'file scope revived after a temporary replacement')
local bad,why=fixture(raw,text,{source_path='OEBPS/text/chapter-002.xhtml'})
expect(not bad and why=='source_dom/chapter_mismatch','DOM Source mismatch accepted')
local unavailable=archive[Source.meta_path(11)]
archive[Source.meta_path(11)]=nil
expect(not Dom.open(doc,'synthetic-dom',11),'legacy file guessed provenance')
archive[Source.meta_path(11)]=unavailable
archive['OEBPS/content.opf']=archive['OEBPS/content.opf']:gsub('</spine>','<itemref idref="c"/></spine>')
local ambiguous,ambiguous_error=Dom.open(doc,'synthetic-dom',11)
expect(not ambiguous and ambiguous_error=='source_dom/spine_ambiguous','repeated spine member accepted')
local cancel=true
local cancelled,cancel_reason=fixture(raw,text,{is_current=function() return cancel end,yield=function() cancel=false end})
expect(not cancelled and cancel_reason=='source_dom/cancelled','cancelled preparation committed')
local private,private_reason=Dom.open({getDocumentFileContent=function() error('private credentials') end},'b',11)
expect(not private and not private_reason:find('private',1,true),'native failure leaked diagnostic')
-- A sparse index remains bounded under repeated and overlapping requests.
local paragraphs,plain={},{}
for n=1,1000 do
    paragraphs[#paragraphs+1]='<p>Number'..n..' abcdefghijklmnopqrstuvwxyz.</p>'
    plain[#plain+1]='Number'..n..' abcdefghijklmnopqrstuvwxyz.'
end
local long_raw='<html><body>'..table.concat(paragraphs)..'</body></html>'
local long_index=assert(fixture(long_raw,table.concat(plain,'\n')))
local long_map=assert(Coordinates.build(long_raw))
local early=assert(long_map:locate('Number5abcdefghijklmnopqrstuvwxyz.'))
expect(long_index:locate(early.co),'long chapter failed')
expect(long_index.stats.checkpoints>100 and long_index.stats.checkpoints<200,'index is not sparse')
local steps=long_index.stats.steps
expect(long_index:locate(early.co),'cached lookup failed')
expect(long_index.stats.steps-steps<=Dom.CHECKPOINT_INTERVAL+100,'repeat query walked whole chapter')
-- Cancelling an in-progress walk permanently invalidates that operation's index.
local active=true
long_index.options.is_current=function() return active end
long_index.options.yield=function() active=false end
long_index.stats.steps=127
local aborted,abort_reason=long_index:locate(early.co)
expect(not aborted and abort_reason=='source_dom/cancelled','walk committed after cancellation')
active=true
expect(not long_index:locate(early.co),'cancelled index revived after session changed back')
-- A corrupted native walk must fail both full-quote and prefix checks.
local corrupt=assert(fixture(raw,text))
corrupt.document.getPrevVisibleChar=function() return xp(0) end
local rejected,reject_reason=corrupt:locate(point.co)
expect(not rejected and reject_reason=='source_dom/walk_diverged','wrong DOM walk accepted')
expect(not corrupt:locate(point.co),'diverged checkpoint reused')
local _,_,prepared_doc,prepared_archive=fixture(raw,text)
prepared_doc.getHTMLFromXPointers=function(self) return self:getHTMLFromXPointer() end
local native_read=prepared_doc.getDocumentFileContent
prepared_doc.getDocumentFileContent=function(self,name)
    expect(not name:find('/raw-',1,true) and not name:match('^OEBPS/text/'),'prepared DOM read raw/rendered member on UI thread')
    return native_read(self,name)
end
local metadata=prepared_archive[Source.meta_path(11)]
local native_index,prepared_reason=Dom.open_prepared(prepared_doc,'synthetic-dom',metadata)
expect(native_index,prepared_reason)
local prepared_point=assert(native_index:locate_anchor(assert(map:anchor(point.co))))
expect(prepared_point.co==point.co and prepared_point.xpointer==located.xpointer,'prepared anchor changed native scalar point')
expect(not native_index:locate(point.co),'prepared native index rebuilt original source map')
for _,bad_anchor in ipairs({{}, {co=point.co,text='short',point_offset=0,basis='filtered_xhtml_utf16',point_unit='unicode_scalars'},
    {co=point.co,text=assert(map:anchor(point.co)).text,point_offset=99999,basis='filtered_xhtml_utf16',point_unit='unicode_scalars'}}) do
    expect(not native_index:locate_anchor(bad_anchor),'unbounded/invalid prepared anchor accepted')
end
expect(not Dom.open_prepared(prepared_doc,'other',metadata),'foreign prepared metadata accepted')
print(('source_dom_spec: %d checks'):format(checks))

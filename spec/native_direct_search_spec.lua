package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(value)
    return value:gsub('&amp;','&'):gsub('&lt;','<'):gsub('&gt;','>'):gsub('&quot;','"')
end} end
local Crypto=require('weread.lib.crypto')
local Search=require('weread.lib.native_direct_search')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local account='123'
local entry={owner=Crypto.sha256_hex('native-direct-account\0'..account),book_id='42',chapter_uid='37',book_version=1,
    chapter_idx=1,title='Chapter',missing_images=0,text_digest=string.rep('1',64),source_sha256=string.rep('2',64),
    key=string.rep('3',64),copy=0}
local paragraphs={}
for i=1,37 do paragraphs[#paragraphs+1]=string.format('<p>distinct context %03d needle distinct trailing %03d</p>',i,i) end
local raw='<html><body>'..table.concat(paragraphs)..'</body></html>'
local calls,live_state=0,true
local saved={path='/verified.epub',file_id=string.rep('4',64)}
local deps={cache={open=function() calls=calls+1;return saved end},archive={read=function(path,wanted)
    expect(path=='/verified.epub' and wanted['OEBPS/text/chapter.xhtml']~=nil,'wrong archive member')
    return {['OEBPS/text/chapter.xhtml']=raw}
end}}
local function current() return live_state end
local function scan(keyword,from,ignore)
    return Search.scan({},account,entry,keyword,from or 1,ignore,current,deps)
end
local first=scan('needle')
expect(#first.hits==30 and first.next_byte and not first.complete and calls==2,'first batch or file recheck failed')
expect(first.hits[1].chapter_uid=='37' and first.hits[1].file_id==saved.file_id
    and first.hits[1].anchor.basis=='filtered_xhtml_utf16' and first.hits[1].context:find('needle',1,true),
    'local result lacks a verifiable anchor')
local second=scan('needle',first.next_byte)
expect(#second.hits==7 and second.complete and first.hits[1].anchor.co~=second.hits[1].anchor.co,
    'continuation lost or repeated results')
local folded=scan('NeEdLe',1,true)
expect(#folded.hits==30 and folded.hits[1].anchor.co==first.hits[1].anchor.co,'case fold changed location')
expect(#scan('NeEdLe',1,false).hits==0,'case-sensitive search ignored case')
expect(scan(' ',1).error=='invalid' and scan('needle',0).error=='invalid'
    and scan('needle',1,'yes').error=='invalid','invalid query accepted')
expect(Search.scan({},'999',entry,'needle',1,false,current,deps).error=='invalid','other account searched cache')
live_state=false;expect(scan('needle').error=='invalid','stale session accepted');live_state=true
local original=deps.cache.open
calls=0;deps.cache.open=function() calls=calls+1;return calls==1 and saved or nil end
expect(scan('needle').error=='unavailable','changed file accepted after scanning')
deps.cache.open=original
local original_read=deps.archive.read
deps.archive.read=function() live_state=false;return {['OEBPS/text/chapter.xhtml']=raw} end
expect(scan('needle').error=='cancelled','cancelled scan returned results');live_state=true
deps.archive.read=function() return {} end
expect(scan('needle').error=='unavailable','missing archive content accepted')
deps.archive.read=original_read
raw='<html><body><p>中文 English needle 结束，唯一上下文用于校验定位。</p></body></html>'
local chinese=scan('中文 English')
expect(#chinese.hits==1 and chinese.hits[1].context:find('中文 English',1,true),'mixed-language query failed')
print(('native_direct_search_spec: %d checks'):format(checks))

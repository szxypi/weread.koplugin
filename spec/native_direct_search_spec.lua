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
local function resolve(selected,keyword,ignore)
    return Search.find_hit({},account,entry,keyword or 'needle',selected,ignore,current,deps)
end
local Coordinates=require('weread.lib.source_coordinates');local build=Coordinates.build;local anchors=0
Coordinates.build=function(...)
    local map=build(...);local anchor=map.anchor
    map.anchor=function(...)
        anchors=anchors+1
        return anchor(...)
    end
    return map
end
local selected=first.hits[1]
calls=0;local resolved=resolve(selected)
Coordinates.build=build
expect(resolved.path==saved.path and resolved.hit.byte==selected.byte and resolved.hit.anchor.co==selected.anchor.co
    and resolved.hit.file_id==selected.file_id and calls==2 and anchors==1,'selected match scanned more than its own anchor')
expect(resolve({file_id=selected.file_id,byte=selected.byte+1}).error=='changed','a later match replaced the selected byte')
local read=deps.archive.read
deps.archive.read=function() error('wrong file reached the archive') end
expect(resolve({file_id=string.rep('5',64),byte=selected.byte}).error=='changed','wrong file was searched')
deps.archive.read=read
local second=scan('needle',first.next_byte)
expect(#second.hits==7 and second.complete and first.hits[1].anchor.co~=second.hits[1].anchor.co,
    'continuation lost or repeated results')
deps.max_hits=7
local exact_end=scan('needle',first.next_byte)
expect(exact_end.complete and not exact_end.next_byte and #exact_end.hits==7
    and exact_end.hits[7].byte==second.hits[7].byte,'an exact-full scan reported another batch')
deps.max_hits=1
local limited=scan('needle')
expect(#limited.hits==1 and limited.next_byte and limited.hits[1].byte==first.hits[1].byte
    and scan('needle',limited.next_byte).hits[1].byte==first.hits[2].byte,
    'the requested result limit skipped or duplicated a byte on resume')
deps.max_hits=0;expect(scan('needle').error=='invalid','empty scan budget was accepted')
deps.max_hits=nil
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
calls=0;expect(resolve(selected).error=='unavailable','changed file accepted after resolving the selected match')
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
local mixed=resolve(chinese.hits[1],'中文 eNglIsh',true)
expect(mixed.hit and mixed.hit.byte==chinese.hits[1].byte,'case-insensitive selection lost its original byte')
print(('native_direct_search_spec: %d checks'):format(checks))

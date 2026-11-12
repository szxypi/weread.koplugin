package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(s)
    return s:gsub('&amp;','&'):gsub('&lt;','<'):gsub('&gt;','>'):gsub('&quot;','"')
end} end
local Target=require('weread.lib.my_mark_target')
local Crypto=require('weread.lib.crypto')
local checks=0
local function eq(a,b) checks=checks+1;assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function count(s) local n=0;for _char in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do n=n+1 end;return n end
local function row(raw,quote,start)
    raw=raw:gsub('^\239\187\191','')
    local at=start or assert(raw:find(quote,1,true))-1
    local first=count(raw:sub(1,at))
    return {type=1,chapterUid=2,markText=quote,range=tostring(first)..'-'..tostring(first+count(quote))}
end
local function check(raw,mark,offset)
    local value,reason=Target.project(raw,'41','2',mark);assert(value,reason)
    eq(value.chapter_offset,offset);eq(value.book_id,'41');eq(value.chapter_uid,'2')
    eq(value.raw_sha256,Crypto.sha256_hex(raw));eq(value.raw_bytes,#raw)
    eq(value.basis,'filtered_xhtml_utf16');eq(value.upload_verified,false)
end
local quote='Unique selected text'
local raw='<html><body><p>'..quote..' content.</p></body></html>'
eq(Target.can_locate(row(raw,quote)),true)
for _i,item in ipairs({{}, {type=1,chapterUid=2,markText=quote}, {type=0,chapterUid=2,markText=quote,range='15-35'},
    {type=1,chapterUid=0,markText=quote,range='15-35'},{type=1,chapterUid=2,markText=quote,range='35-15'}}) do eq(Target.can_locate(item),false) end
check(raw,row(raw,quote),15)
check('\239\187\191'..raw,row(raw,quote),16)
local emoji='<html><body><p>😀 '..quote..' content.</p></body></html>'
check(emoji,row(emoji,quote),18)
local ignored='<html><body><p>prefix<a href="https://example.invalid/">'..quote..'</a> tail</p></body></html>'
check(ignored,row(ignored,quote),21)
local repeated='<html><body><p>First context before YES after first instance.</p><p>Second context before YES after second instance.</p></body></html>'
local at=assert(repeated:find('YES',assert(repeated:find('Second',1,true)),true))-1
check(repeated,row(repeated,'YES',at),at)
local block='<p>'..string.rep('identical long context ',20)..'YES'..string.rep(' identical suffix',20)..'</p>'
local duplicate='<html><body>'..block..block..'</body></html>'
local refused,why=Target.project(duplicate,'41','2',row(duplicate,'YES'));eq(refused,nil);eq(why,'my_mark_target/unmatched')
local edges='<html><body><p>\n  '..quote..' \t\n</p></body></html>'
check(edges,{type=1,chapterUid=2,markText=quote,range='15-41'},18)
local html='<html><body><p>Unique &amp; selected <b>text</b> content.</p></body></html>'
check(html,{type=1,chapterUid=2,markText='Unique & selected text',range='15-48'},15)
local comment='<html><body><!-- hidden > quote --><p>left <3 &amp; right more text</p></body></html>'
local start=assert(comment:find('left',1,true))-1;local finish=assert(comment:find('</p>',1,true))-1
check(comment,{type=1,chapterUid=2,markText='left <3 & right more text',range=start..'-'..finish},start)
for _i,change in ipairs({{type=0},{chapterUid=3},{bookId='99'},{range='1-99999'},{range='40-15'},
    {range=true},{markText='Different selected text'},{markText='Unique  selected text'}}) do
    local mark=row(raw,quote);for k,v in pairs(change) do mark[k]=v end
    local value,reason=Target.project(raw,'41','2',mark);eq(value,nil);eq(reason:match('^my_mark_target/[a-z_]+$')~=nil,true)
end
local hidden='<html><head><title>'..quote..'</title></head><body><p>'..quote..'</p></body></html>'
refused,why=Target.project(hidden,'41','2',row(hidden,quote));eq(refused,nil);eq(why,'my_mark_target/quote_changed')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local book={book_id='41',bookVersion=7}
local chapter={chapterUid='2'}
local capture=assert(Source.capture(book,chapter,raw,'web_xhtml'))
local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(raw))
local identity=assert(Identity.decode(root));local path='OEBPS/text/chapter.xhtml'
local metadata=assert(Source.bind(capture,identity,path,Crypto.sha256_hex(raw)))
local members={[Identity.PATH]=root,[Source.meta_path('2')]=metadata,[Source.path_meta_path(path)]=metadata,
    [Source.raw_path(Crypto.sha256_hex(raw))]=raw,[path]=raw}
local reads=0
local function archive(file,wanted)
    reads=reads+1;assert(file=='/cached.epub')
    local result={};for key,limit in pairs(wanted) do assert(members[key] and #members[key]<=limit);result[key]=members[key] end
    return result
end
local bound=Target.bind_file('/cached.epub','41',row(raw,quote),17,archive)
eq(bound.position.chapter_offset,15);eq(bound.position.file_id,identity.file_id);eq(bound.metadata,metadata)
eq(bound.request_id,17);eq(bound.file,'/cached.epub');eq(bound.identity.file_id,identity.file_id);eq(reads,4)
eq(bound.raw,nil);eq(bound.position.upload_verified,false);eq(bound.position.percent,nil)
for _i,key in ipairs({Identity.PATH,Source.meta_path('2'),Source.path_meta_path(path),Source.raw_path(Crypto.sha256_hex(raw)),path}) do
    local prior=members[key];members[key]='changed'
    eq(Target.bind_file('/cached.epub','41',row(raw,quote),17,archive).position,nil)
    members[key]=prior
end
eq(Target.bind_file('/cached.epub','99',row(raw,quote),17,archive).position,nil)
eq(Target.bind_file('/bad','41',row(raw,quote),17,archive).position,nil)
eq(Target.bind_file('/cached.epub','41',{type=1,chapterUid=3,markText=quote,range='15-35'},17,archive).position,nil)
local candidates={}
local function candidates_archive(file,wanted)
    candidates[#candidates+1]=file
    return archive(file,wanted)
end
local resolved=Target.resolve({book_id='41',cached_chapters={['2']='/cached.epub'},cached_full_book='/other.epub'},'/wrong.epub',row(raw,quote),19,candidates_archive)
eq(resolved.position.chapter_offset,15);eq(candidates[1],'/wrong.epub');eq(candidates[2],'/cached.epub')
eq(#candidates,5)
reads=0;resolved=Target.resolve({book_id='41',cached_file='/cached.epub',cached_full_book='/cached.epub',cached_chapters={['2']='/cached.epub'}},'/cached.epub',row(raw,quote),20,function() reads=reads+1;error('invalid archive') end)
eq(resolved.position,nil);eq(reads,1)
print('my_mark_target_spec: '..checks..' source-bound target checks passed')

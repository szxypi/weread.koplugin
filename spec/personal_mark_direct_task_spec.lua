package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(s) return s:gsub('&amp;','&') end} end
local Crypto=require('weread.lib.crypto')
local raw='<html><body><p>Unique &amp; selected <b>text</b> content that remains intact.</p></body></html>'
local owner,live='123',true
local scope={vid=owner}
local entry={book_id='41',chapter_uid='2',book_version=7,file_id=string.rep('a',64),key=string.rep('b',64),source_sha256=Crypto.sha256_hex(raw)}
local settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_,s) return live and s==scope end}
local saved,fetches,writes=nil,0,0
package.preload['weread.lib.native_direct_cache']=function() return {valid_entry=function(e,book,vid)
    return e==entry and book=='41' and vid==owner
end} end
package.preload['weread.lib.native_direct_mark_source_store']=function() return {new=function() return {
    read=function() return saved end,write=function(_,e,value) assert(e==entry and value==raw);saved=value;writes=writes+1;return true end,
} end} end
package.preload['weread.lib.native_read_access']=function() return {capture=function() return {} end} end
package.preload['weread.lib.source_currentness']=function() return {capture=function() return {} end} end
package.preload['weread.lib.native_direct_position']=function() return {verified_source=function(_,_,e,_,_,_,current)
    assert(e==entry and current());fetches=fetches+1;return raw
end} end
local Task=require('weread.lib.personal_mark_task')
local metadata=entry.file_id..entry.source_sha256..entry.key
local row={bookmarkId='synthetic-own',type=1,chapterUid=2,markText='Unique & selected text',range='15-48'}
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
expect(not pcall(Task.prepare_direct,{},settings,{},'/book.epub',entry,metadata,{row},false),'offline without source displayed')
expect(fetches==0 and writes==0,'offline tried to fetch')
local first=Task.prepare_direct({},settings,{},'/book.epub',entry,metadata,{row},true)
expect(#first.rows==1 and first.rows[1].bookmarkId==row.bookmarkId and fetches==1 and writes==1,'verified online source not cached')
local again=Task.prepare_direct({},settings,{},'/book.epub',entry,metadata,{row},false)
expect(#again.rows==1 and fetches==1 and writes==1,'cached source unavailable offline')
local bad={bookmarkId=row.bookmarkId,type=1,chapterUid=2,markText='Changed quote',range=row.range}
expect(#Task.prepare_direct({},settings,{},'/book.epub',entry,metadata,{bad},false).rows==0,'wrong quotation accepted')
expect(not pcall(Task.prepare_direct,{},settings,{},'/book.epub',entry,metadata..'x',{row},false),'different file identity accepted')
live=false;expect(not pcall(Task.prepare_direct,{},settings,{},'/book.epub',entry,metadata,{row},false),'expired account scope accepted')
live=true;scope={vid='456'};expect(not pcall(Task.prepare_direct,{},settings,{},'/book.epub',entry,metadata,{row},false),'different account accepted')
print('personal_mark_direct_task_spec: '..checks..' checks passed')

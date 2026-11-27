package.path='./?.lua;'..package.path
local Path=require('weread.lib.native_direct_path')
local settings={data_dir='/data/weread',cache_dir='/data/weread',get=function(_,key)
    if key=='books' then return {['42']={cached_file='/data/weread/native-reader-v1/a/book.epub'}} end
    return {}
end}
local file='/data/weread/native-reader-v1/a/book.epub'
assert(Path.contains(settings,file) and not Path.contains(settings,'/data/weread/native-reader-v1-old/a.epub')
    and not Path.contains(settings,'/data/other/book.epub') and not Path.contains({},file))
package.preload['weread.lib.content']=function() return {book_resolved_dir=function(s,id,book)
    return book.cache_dir or s.cache_dir..'/'..id
end} end
package.preload['weread.lib.logger']=function() return {scoped=function() return {} end} end
package.preload['ui/uimanager']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end,T=function(s) return s end} end
local Lifecycle=require('weread.lib.reader_lifecycle')
local host={ui={document={file=file}},settings=settings}
assert(Lifecycle.detectWeReadBook(host)==nil,'native-only file acquired an ordinary book identity')
host.ui.document.file='/data/weread/42/book.epub'
assert(Lifecycle.detectWeReadBook(host)=='42','ordinary cached book was excluded')
local Report=require('weread.lib.read_report')
local doc={file=file}
local report=setmetatable({settings=settings,get_document=function() return doc end,
    detect_book=function() return '42' end,_config=function() return {mode='manual',book_id='42'} end},Report)
local book,_,reason=report:resolve_target()
assert(not book and reason=='native_direct_local_only','manual read-time mode bypassed native-only isolation')
doc.file='/data/weread/42/book.epub'
assert(report:resolve_target()=='42','ordinary manual read-time target changed')

local reads,epoch=0,0
local books={['42']={cache_dir='/library/42/'}}
local indexes={['42']={cache_dir='/library/42'}}
local indexed={data_dir='/data/weread',cache_dir='/data/weread',get_book_indexes=function() return indexes end,
    get=function(_,key)
        if key=='books' then reads=reads+1;return books end
        assert(key=='auth_epoch');return epoch
    end}
local reader={ui={document={file='/library/42/book.epub'}},settings=indexed}
local function detect() return Lifecycle.detectWeReadBook(reader) end
assert(detect()=='42' and reads==1,'initial lookup did not establish the stored directory')
for _=1,100 do assert(detect()=='42') end
assert(reads==1,'page captures reloaded unrelated book records')
reader._personal_original_local_only=reader.ui.document.file
assert(detect()==nil and reads==1,'memoized path enabled sync for an original PDF')
reader._personal_original_local_only=nil
epoch=1
assert(detect()=='42' and reads==2,'login change did not revalidate the stored path')
indexed.cache_dir='/new-cache'
assert(detect()=='42' and reads==3,'download-directory change invalidated a stored moved book')

indexes={['43']={cache_dir='/library/42'}}
books={['43']={cache_dir='/library/42'}}
assert(detect()=='43' and reads==4,'new index reused a prior book identity')
indexes['43'].cache_dir='/library/moved';books['43'].cache_dir='/library/moved'
assert(detect()==nil and reads==5,'in-place directory move kept the old route')
reader.ui.document.file='/library/moved/book.epub'
assert(detect()=='43' and reads==6,'the moved book was not recognized')
reader.ui.document.file='/legacy/old.epub';books['43'].cached_file=reader.ui.document.file
assert(detect()=='43' and reads==7,'legacy exact file outside cache directory was not recognized')
books['43'].cached_file=nil
assert(detect()==nil and reads==8,'legacy exact file used stale metadata after removal')
reader.ui.document.file='/library/moved-old/book.epub'
assert(detect()==nil and reads==9,'directory prefix matched a neighboring cache')
reader.ui.document.file='/new-cache/765/book.epub'
assert(detect()=='765' and reads==10,'unindexed cached directory fallback was lost')
for _,path in ipairs({file,'/data/weread/exports/notes/book.md','/data/weread/exports/articles/book.epub'}) do
    reader.ui.document.file=path;books['43'].cached_file=path
    assert(detect()==nil and reads==10,'a local-only path acquired normal book identity')
end
print('PASS: cached book routing, live legacy metadata and local-only file isolation')

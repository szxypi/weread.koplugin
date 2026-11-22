package.path='./?.lua;'..package.path
local Path=require('weread.lib.native_direct_path')
local settings={data_dir='/data/weread',cache_dir='/data/weread',get=function(_,key)
    if key=='books' then return {['42']={cached_file='/data/weread/native-reader-v1/a/book.epub'}} end
    return {}
end}
local file='/data/weread/native-reader-v1/a/book.epub'
assert(Path.contains(settings,file) and not Path.contains(settings,'/data/weread/native-reader-v1-old/a.epub')
    and not Path.contains(settings,'/data/other/book.epub') and not Path.contains({},file))
package.preload['weread.lib.content']=function() return {book_resolved_dir=function() return '/data/weread/42' end} end
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
print('PASS: native-only files remain local for automatic and manual reporting')

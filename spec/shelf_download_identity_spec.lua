package.path='./?.lua;'..package.path
for _,name in ipairs({'ui/widget/buttondialog','ui/widget/confirmbox','ui/widget/pathchooser','ui/uimanager'}) do
    package.preload[name]=function() return {} end
end
package.preload['weread.lib.logger']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {
    tr=function(v) return v end,T=function(v) return v end,log_error=tostring,display_error=tostring,
    file_exists=function(path) return path=='/synthetic/book.epub' end,
} end
local Cache=require('weread.ui.cache')
local host={settings={get=function() return {} end}}
for key,value in pairs(Cache) do host[key]=value end
local function downloaded(book,records,cache) return host:isBookDownloaded(book,records,cache) end
local saved={[42]={book_id='42',cached_full_book='/synthetic/book.epub'}}
assert(downloaded({bookId='42'},saved),'safe old numeric key not recognized')
assert(downloaded({bookId=42},saved),'numeric shelf ID not recognized')
assert(not downloaded({bookId='43'},saved),'unrelated book marked downloaded')
assert(not downloaded({bookId='42',book_id='43'},saved),'conflicting shelf identity accepted')
saved['42']={book_id='43',cached_file='/synthetic/book.epub'}
assert(not downloaded({bookId='42'},saved),'mismatched exact record accepted or numeric record bypassed')
saved['42']={book_id='42',bookId='43',cached_file='/synthetic/book.epub'}
assert(not downloaded({bookId='42'},saved),'conflicting record identifiers accepted')
saved={['CB_book']={book_id='CB_book',cached_chapters={['1']='/synthetic/book.epub'}}}
assert(downloaded({bookId='CB_book'},saved),'imported book chapter not recognized')
assert(not host:bookRecordHasDownload({cached_chapters='invalid'}),'malformed chapter cache accepted')
local huge='9007199254740993'
saved={[9007199254740992]={cached_file='/synthetic/book.epub'}}
assert(not downloaded({bookId=huge},saved),'rounded numeric key attached a different book')
assert(not downloaded({bookId=9007199254740992},saved),'imprecise numeric shelf identifier accepted')
saved[huge]={book_id=huge,cached_file='/synthetic/book.epub'}
assert(downloaded({bookId=huge},saved),'exact large string identity rejected')
local cache={}
assert(downloaded({bookId=42},{[42]={cached_file='/synthetic/book.epub'}},cache))
assert(not downloaded({bookId='42',book_id='43'},{},cache),'cache bypassed conflicting shelf identifiers')
print('PASS: shelf downloaded state uses exact book identities')

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
local owner=require('weread.lib.crypto').sha256_hex('weread-library:123'):sub(1,20)
local scope={vid='123',epoch=1};local calls,repairs=0,0
local checks=0
host.settings.get_auth_scope=function() return scope end
host.settings.auth_scope_matches=function(_,value) checks=checks+1;return value==scope end
host.library_db={accountKey=function() return owner end}
package.loaded['weread.lib.native_direct_cache']={
    present=function(_,vid,id,current,allow_read)
        calls=calls+1
        if id~='42' and id~='43' then return false end
        if allow_read and not allow_read() then return false end
        if vid=='123' and id=='42' then return true end
        if not current then return false end
        repairs=repairs+1;return vid=='123' and id=='43' and current()
    end,
}
for id=100,131 do assert(not downloaded({bookId=tostring(id)},{})) end
assert(checks==0,'missing native directories caused disk authorization reads')
for id=100,131 do
    assert(not host:nativeChapterCachePresent(tostring(id),function() error('absent cache started a repair') end))
end
assert(checks==0,'download worker reread authorization for books without native directories')
assert(downloaded({bookId='42'},{}),'native cached chapter was not recognized')
assert(checks==1,'existing native cache was not authorized exactly once')
assert(not downloaded({bookId='43'},{}),'another book acquired native cache status')
local before=calls
assert(repairs==0,'shelf checks tried to repair the marker')
assert(host:nativeChapterCachePresent('42',function() error('valid marker started a scan') end))
assert(host:nativeChapterCachePresent('43',function() return true end),'download worker did not use repair')
assert(not host:nativeChapterCachePresent('43',function() return false end),'cancelled worker retained its result')
assert(calls==before+3 and repairs==2,'download worker repeated the marker lookup')
before=calls
assert(not downloaded({bookId='42'},{['42']={book_id='43'}}),'native hint bypassed conflicting saved identity')
assert(calls==before,'conflicting record consulted native cache hint')
host.library_db.accountKey=function() return 'other-account' end
assert(not downloaded({bookId='42'},{}),'different library account inherited native cache status')
host.library_db.accountKey=function() return owner end
host.settings.auth_scope_matches=function() return false end
assert(not downloaded({bookId='42'},{}),'stale authorization inherited native cache status')
assert(not host:nativeChapterCachePresent('43',function() error('stale authorization started a repair') end))
assert(repairs==2,'download worker read a marker or started repair with stale authorization')
local loaded
host.settings.book_lookup=function()
    return function(id)
        assert(not loaded,'standalone badge loaded more than one book')
        loaded=id
        return {book_id=id,cached_full_book='/synthetic/book.epub'}
    end
end
assert(downloaded({bookId='42'}) and loaded=='42','standalone badge did not use the indexed book lookup')
print('PASS: shelf downloaded state uses exact book identities')

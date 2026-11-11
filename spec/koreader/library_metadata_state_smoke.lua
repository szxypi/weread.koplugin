require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'))
assert(require('libs/libkoreader-lfs').mkdir(root))
local json=require('json')
local library=require('weread.lib.library_db'):new{data_dir=root,get=function(_self,key,default)
    return key=='account' and {user_vid='900000'} or default
end}
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local book={book_id='41',title='Synthetic metadata',cached_full_book='/synthetic/full.epub',
    progress=84,pending_upload_position={chapter_uid=2,chapter_offset=100},pending_upload_account='synthetic-owner',
    pending_upload_reason='page_changed',source_dispatch={phase='acknowledged'},last_uploaded_position={chapter_offset=200}}
expect(library:putBook(book),'metadata write failed')
local db=assert(library:open())
local payload=json.decode(db:rowexec("SELECT detail_payload FROM books WHERE book_id='41'"))
expect(payload.title==book.title and payload.cached_full_book==book.cached_full_book,'metadata/cache path lost')
expect(not payload.pending_upload_position and not payload.pending_upload_account and not payload.source_dispatch
    and not payload.progress and not payload.last_uploaded_position,'new SQLite detail contains reading state')
expect(book.progress==84 and book.pending_upload_position.chapter_offset==100,'write mutated caller')
local stmt=db:prepare("UPDATE books SET detail_payload=? WHERE book_id='41'")
stmt:bind(json.encode(book)):step();stmt:close();db:close()
local legacy=assert(library:getBook('41'))
expect(legacy.title==book.title and legacy.cached_full_book==book.cached_full_book,'legacy metadata lost')
for key in pairs(book) do
    if require('weread.lib.book_store').is_reading_field(key) then expect(legacy[key]==nil,'legacy checkpoint field returned: '..key) end
end
db=assert(library:open());payload=json.decode(db:rowexec("SELECT detail_payload FROM books WHERE book_id='41'"));db:close()
expect(payload.pending_upload_position.chapter_offset==100,'read unexpectedly rewrote legacy database')
expect(library:getBook('missing')==nil,'missing metadata became a record')
print('PASS: metadata/checkpoint isolation with real SQLite ('..checks..' checks)')

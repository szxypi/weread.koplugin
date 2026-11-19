-- Exercise SQLite locking and old account databases with the actual KOReader binding.
require('setupkoenv')
package.path=assert(os.getenv('WEREAD_SOURCE'))..'/?.lua;'..package.path
local root=assert(os.getenv('WEREAD_LIBRARY_TEST_DIR'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(root..'/settings.reader.lua')
local lfs=require('libs/libkoreader-lfs')
local SQ3=require('lua-ljsqlite3/init')
local Library=require('weread.lib.library_db')
local account='900001'
local settings={data_dir=root,cache_dir=root..'/cache',get=function(_self,key,default)
    if key=='account' then return account and {user_vid=account} or {} end
    return default
end}
local store=Library:new(settings)
local missing=assert(store:databasePath())
local json=require('json')
local codec={json_encode=function(_self,value) return json.encode(value) end,
    json_decode=function(_self,value) return json.decode(value) end}
local note_store=require('weread.lib.my_cloud_marks_store')
local marks=note_store:new(store,codec)
local thoughts=note_store:new(store,codec,'thoughts')
assert(not lfs.attributes(missing) and not store:getChapters('100'))
assert(#assert(marks:list_ids())==0 and #assert(thoughts:list_ids())==0 and not marks:read('100'))
assert(not lfs.attributes(missing),'a read created an account database')
assert(store:putChapters('100',{{chapterUid=1,title='old'}}))
assert(store:cacheShelf({{bookId='100',title='shelf'}},{{archiveId='5',title='group'}}))
assert(store:putBook({bookId='100',title='detail'}))
assert(store:putProfileState('statistics',{value=7}))
assert(store:putShelfProgress({{book_id='100',value=23}}))
local notebook=require('weread.lib.notebook_catalog_store'):new(store,codec,store:accountKey())
assert(notebook:write({schema=1,fetched_at=1000,books={{bookId='100',title='book',author='author'}}}))
assert(#assert(marks:list_ids())==0 and #assert(thoughts:list_ids())==0)
assert(marks:write({schema=1,book_id='100',fetched_at=1000,
    updated={{bookmarkId='mark',type=1,markText='quote'}},chapters=json.decode('[]')}))
assert(thoughts:write({schema=1,book_id='100',fetched_at=1000,
    reviews={{reviewId='thought',content='note'}}}))

-- A shared reader prevents switching a rollback-journal database to WAL,
-- but a second read can still safely observe the committed catalog.
local lock=assert(store:open())
lock:exec('PRAGMA journal_mode=DELETE')
lock:exec('BEGIN')
assert(lock:rowexec('SELECT count(*) FROM chapters')==1)
local rows=assert(store:getChapters('100'))
assert(#rows==1 and rows[1].title=='old')
assert(store:getShelf()[1].title=='shelf' and store:getShelfArchives()[1].title=='group')
assert(store:getBook('100').title=='detail' and store:getShelfEntry('100').book.title=='shelf')
assert(store:getShelfStatus('100').present==true and store:getShelfStatus('101').present==false)
assert(store:getProfileState('statistics').value==7 and store:getShelfProgress({'100'})['100'].value==23)
assert(notebook:read().books[1].title=='book')
assert(marks:read('100').updated[1].markText=='quote' and thoughts:read('100').reviews[1].content=='note')
assert(marks:list_ids()[1]=='100' and thoughts:list_ids()[1]=='100')
local host={settings=settings,library_db=store,client=codec}
local book={book_id='100'}
rows=assert(require('weread.lib.reader_lifecycle').ensureChaptersLoaded(host,book))
assert(#rows==1 and rows[1].title=='old' and book.chapters==rows,'reader did not restore its catalog')
assert(lock:rowexec('PRAGMA journal_mode')=='delete','read changed journal mode')
lock:exec('ROLLBACK');lock:close()

-- A genuinely unreadable existing cache must not be reported as empty.
local exclusive=assert(SQ3.open(assert(store:databasePath())))
exclusive:exec('BEGIN EXCLUSIVE')
assert(not store:getShelf() and not store:getShelfStatus('100') and not notebook:read())
assert(not marks:list_ids() and not thoughts:list_ids() and not marks:read('100'))
exclusive:exec('ROLLBACK');exclusive:close()

-- WAL readers must see committed data while a writer holds uncommitted data.
local writer=assert(store:open())
writer:exec('BEGIN IMMEDIATE')
writer:exec([[UPDATE chapters SET payload='{"chapterUid":1,"title":"new"}' WHERE book_id='100']])
rows=assert(store:getChapters('100'));assert(#rows==1 and rows[1].title=='old')
writer:exec('COMMIT');writer:close()
rows=assert(store:getChapters('100'));assert(#rows==1 and rows[1].title=='new')

-- Reads do not migrate old schemas; the existing write open still does so.
account='900002'
local legacy=assert(SQ3.open(assert(store:databasePath())))
legacy:exec([[CREATE TABLE books (book_id TEXT PRIMARY KEY,kind TEXT NOT NULL DEFAULT 'book',payload TEXT NOT NULL,
    on_shelf INTEGER NOT NULL DEFAULT 0,shelf_position INTEGER,shelf_updated_at INTEGER,detail_updated_at INTEGER)]])
legacy:exec([[CREATE TABLE chapters (book_id TEXT NOT NULL,chapter_uid TEXT NOT NULL,position INTEGER NOT NULL,
    payload TEXT NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(book_id,chapter_uid))]])
legacy:exec([[INSERT INTO chapters VALUES('200','4',1,'{"chapterUid":4,"title":"legacy"}',0)]])
legacy:exec([[INSERT INTO books(book_id,payload,on_shelf) VALUES('200','{"bookId":"200","title":"legacy book"}',1)]])
legacy:exec([[CREATE VIEW my_cloud_marks AS SELECT 'invalid' AS book_id]])
legacy:close()
rows=assert(store:getChapters('200'));assert(#rows==1 and rows[1].title=='legacy')
assert(store:getBook('200').title=='legacy book' and store:getShelf()[1].title=='legacy book')
assert(not marks:list_ids() and #assert(thoughts:list_ids())==0,'invalid cache schema was treated as empty')
legacy=assert(SQ3.open(assert(store:databasePath()),'ro'))
assert(legacy:rowexec([[SELECT count(*) FROM pragma_table_info('books') WHERE name='detail_payload']])==0)
legacy:close()
legacy=assert(store:open())
assert(legacy:rowexec([[SELECT count(*) FROM pragma_table_info('books') WHERE name='detail_payload']])==1)
legacy:close()
assert(not store:getChapters('100'),'catalog leaked between accounts')
assert(not marks:read('100') and not thoughts:read('100'),'note cache leaked between accounts')
account=nil;assert(not store:getChapters('200') and not marks:list_ids(),'signed-out catalog read succeeded')
print('PASS: read-only catalog lookup, SQLite contention, snapshots and legacy migration')

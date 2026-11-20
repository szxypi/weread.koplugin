package.path = "./?.lua;./?/init.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
package.preload["lua-ljsqlite3/init"] = function() return { open = helper.connect } end
local LibraryDB = require("weread.lib.library_db")
local user = os.tmpname()
os.remove(user)
local account = { user_vid = user }
local settings = { data_dir = "/tmp", get = function() return account end }
local db = LibraryDB:new(settings)
local path = db:databasePath()
local books = { { bookId = "1", title = "One" } }
local archives = { { archiveId = 5, name = "History", bookIds = { "1" } } }
assert(db:cacheShelf(books), "legacy shelf cache failed")
assert(db:getShelfArchives() == nil, "legacy cache invented group metadata")
assert(db:cacheShelf(books, archives))
db = LibraryDB:new(settings)
assert(db:getShelf()[1].bookId == "1" and db:getShelfArchives()[1].archiveId == '5',
    "shelf groups did not survive reopening")
assert(db:putBook({book_id='1',finishReading=1,secret=1,isTop=true}), 'detail snapshot failed')
local entry=assert(db:getShelfEntry('1'))
assert(entry.book.finishReading==nil and entry.cached_at>0,'detail flags overrode shelf snapshot')
assert(db:cacheShelf({{bookId='1',finishReading=0,finished=1,secret=0,isTop=false}},archives))
entry=assert(db:getShelfEntry('1'))
assert(entry.book.finishReading==0 and entry.book.finished==1 and entry.book.secret==0 and entry.book.isTop==false,
    'fresh shelf flags were replaced by old detail flags')
assert(db:putBook({book_id='not-on-shelf',finishReading=1,secret=1}) and not db:getShelfEntry('not-on-shelf'),
    'local-only details became an on-shelf entry')
local connection = db:open()
connection:exec([[CREATE TRIGGER reject_archive BEFORE UPDATE ON shelf_state
    BEGIN SELECT RAISE(ABORT, 'fixture failure'); END]])
connection:close()
assert(not db:cacheShelf({ { bookId = "2" } }, {}), "failed group write was accepted")
assert(db:getShelf()[1].bookId == "1" and db:getShelfArchives()[1].archiveId == '5',
    "group failure did not roll back book membership")
connection = db:open()
connection:exec("DROP TRIGGER reject_archive")
connection:close()
account = { user_vid = user .. "-other" }
local other_path = db:databasePath()
local other_books=db:getShelf()
assert((not other_books or #other_books == 0) and db:getShelfArchives() == nil, "groups leaked into another account")
assert(not db:getShelfEntry('1'),'shelf state leaked into another account')
account = { user_vid = user }
assert(db:getShelfArchives()[1].archiveId == '5')
local numeric_book={bookId=100000000000001,title='Exact'}
local numeric_archives={{archiveId=100000000000002,name='Exact group',bookIds={100000000000001}}}
assert(db:cacheShelf({numeric_book},numeric_archives),'numeric shelf did not save')
assert(type(numeric_book.bookId)=='number' and type(numeric_archives[1].bookIds[1])=='number',
    'shelf save changed its input')
assert(db:getShelf()[1].bookId=='100000000000001'
    and db:getShelfArchives()[1].archiveId=='100000000000002'
    and db:getShelfArchives()[1].bookIds[1]=='100000000000001',
    'numeric shelf IDs were not stored as exact strings')
connection=db:open()
local statement=connection:prepare('UPDATE books SET payload=? WHERE book_id=?')
statement:bind(require('json').encode({bookId=100000000000001,title='Legacy'}),'100000000000001'):step()
statement:close();connection:close()
assert(db:getShelf()[1].bookId=='100000000000001'
    and db:getShelfEntry('100000000000001').book.bookId=='100000000000001'
    and db:getShelfStatus('100000000000001').book.bookId=='100000000000001',
    'legacy rounded numeric payload did not recover its SQLite identity')
assert(db:getBook('100000000000001').bookId=='100000000000001',
    'legacy rounded book details did not recover their SQLite identity')
connection=db:open()
statement=connection:prepare('UPDATE books SET payload=? WHERE book_id=?')
statement:bind(require('json').encode({bookId='100000000000000',title='Conflicting'}),'100000000000001'):step()
statement:close();connection:close()
assert(not db:getShelf() and not db:getShelfEntry('100000000000001')
    and not db:getShelfStatus('100000000000001').book and not db:getBook('100000000000001'),
    'conflicting string payload was accepted as the SQLite identity')
assert(db:putBook({bookId=100000000000001,title='Exact details'})
    and db:getBook('100000000000001').bookId=='100000000000001'
    and not db:putBook({bookId=9007199254740992,title='Unsafe details'}),
    'book details did not preserve or safely reject numeric IDs')
assert(db:cacheShelf({}, {}))
assert(#db:getShelf() == 0 and #db:getShelfArchives() == 0, "empty snapshot retained stale data")
assert(not db:getShelfEntry('1'),'removed shelf entry retained a status snapshot')
for _, file in ipairs({ path, other_path }) do
    os.remove(file); os.remove(file .. "-wal"); os.remove(file .. "-shm")
end
helper.cleanup()
print("shelf_snapshot_spec: real SQLite cache, atomic rollback and account isolation passed")

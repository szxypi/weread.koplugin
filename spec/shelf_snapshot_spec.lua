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
assert(db:putShelfProgress({
    {book_id='10',percent=57,exact_percent=57,fetched_at=200,updated_at=190,source='native'},
    {book_id='11',percent=11,exact_percent=11,fetched_at=260,source='web'},
    {book_id='12',percent=5,exact_percent=5,fetched_at=200,updated_at=170,source='web'},
    {book_id='13',percent=61,exact_percent=61,fetched_at=200,source='web'},
}))
local function summary(id,value,updated)
    return {book_id=id,percent=math.floor(value),exact_percent=value,fetched_at=250,updated_at=updated,source='native'}
end
local saved, refreshed = db:putShelfProgress({
    summary('10',1,180), summary('11',12,240), summary('12',7.25,230),
    summary('13',62,200), summary('CB_Imported',0,130),
},true)
assert(saved and refreshed['12'] and refreshed.CB_Imported and not refreshed['10']
    and not refreshed['11'] and not refreshed['13'], 'summary did not report exactly the committed IDs')
local display=db:getShelfProgress({'10','11','12','13','CB_Imported'})
assert(display['10'].percent==57 and display['11'].percent==11 and display['12'].exact_percent==7.25
    and display['13'].percent==61 and display.CB_Imported.exact_percent==0,'summary overwrote newer or conflicting progress')
do
    local ids, progress = {}, {}
    for i=1,520 do
        local id=tostring(200000+i)
        ids[i]=id
        progress[i]=summary(id,(i%100)+0.25,190)
    end
    local exact_id='9007199254740993'
    ids[521],ids[522],ids[523],ids[524]='CB_Imported',exact_id,'missing',200001
    progress[#progress+1]=summary(exact_id,5,190)
    assert(db:putShelfProgress(progress))
    local writer=LibraryDB:new(settings)
    local writable=assert(writer:open())
    writable:exec("UPDATE shelf_progress SET payload='invalid JSON' WHERE book_id='200519'")
    writable:close()
    local old_open,opens,queries,committed=db.openRead,0,0,false
    function db:openRead()
        opens=opens+1
        local reader=assert(old_open(self))
        local prepare=reader.prepare
        reader.prepare=function(read_connection,query)
            local stmt=prepare(read_connection,query)
            if query:find('FROM shelf_progress',1,true) then
                local bind=stmt.bind
                stmt.bind=function(statement,...)
                    queries=queries+1
                    if queries==2 then
                        committed=writer:putShelfProgress({summary('200520',99,240)})
                        assert(committed,'concurrent progress write failed')
                    end
                    return bind(statement,...)
                end
            end
            return stmt
        end
        return reader
    end
    local history=db:getShelfProgress(ids)
    db.openRead=old_open
    assert(committed and opens==1 and queries==3,'full shelf progress did not use bounded queries on one connection')
    assert(history['200520'].exact_percent==20.25 and db:getShelfProgress({'200520'})['200520'].exact_percent==99,
        'a concurrent update mixed progress generations or disappeared on reopen')
    assert(not history['200519'] and not history.missing and history.CB_Imported.exact_percent==0
        and history[exact_id].exact_percent==5 and history['200001'].exact_percent==1.25,
        'batch read lost exact identities, known zero or valid siblings of unavailable progress')
end
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

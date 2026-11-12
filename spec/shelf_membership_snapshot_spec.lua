package.path='./?.lua;'..package.path
local Model=require('weread.lib.shelf_snapshot')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local metadata=assert(Model.metadata({{bookId='42'},{book_id=43,bookId='43'}},1000))
expect(metadata.book_count==2 and metadata.cached_at==1000,'validated member count/time')
local present,stamp=Model.state(metadata,2,1,1000,false)
expect(present==true and stamp==1000,'present row in complete snapshot')
present,stamp=Model.state(metadata,2,nil,nil,false)
expect(present==false and stamp==1000,'absent row in complete snapshot')
expect(Model.state(metadata,2,0,999,false)==false,'old off-shelf detail became a member')
expect(Model.state(nil,0,nil,nil,true)==nil,'missing legacy row declared absent')
expect(Model.state(nil,1,1,800,true)==true,'legacy positive row lost evidence')
expect(Model.state(nil,1,1,800,false)==nil,'broken marker reused legacy fallback')
expect(Model.state(metadata,1,nil,nil,false)==nil,'inconsistent count declared absent')
expect(Model.state(metadata,2,1,999,false)==nil,'different generation declared present')
expect(Model.state(metadata,2,2,1000,false)==nil,'invalid row state')
expect(Model.state({schema=1,book_count=0,cached_at=0},0,nil,nil,false)==false,'verified empty shelf became unknown')
expect(Model.state({schema=1,book_count=0,cached_at=0},0,1,0,false)==nil,'empty snapshot accepted positive row')
for _i,bad in ipairs({0,-1,1.5,math.huge,0/0,'1',true}) do
    local value={schema=bad,book_count=2,cached_at=1000}
    if bad~=1 then expect(Model.state(value,2,nil,nil,false)==nil,'invalid marker schema') end
end
for _i,change in ipairs({'count','time','extra'}) do
    local value={schema=1,book_count=2,cached_at=1000}
    if change=='count' then value.book_count=5001 elseif change=='time' then value.cached_at=-1 else value.extra=true end
    expect(Model.state(value,2,nil,nil,false)==nil,'malformed marker declared absent')
end
for _i,books in ipairs({{bad=true},{{}},{{bookId='0'}},{{bookId='42'},{bookId=42}},
        {{book_id='42',bookId='43'}},{{bookId='bad\nkey'}},{{bookId=9007199254740992}},
        {[1]={bookId='1'},[3]={bookId='3'}}}) do
    expect(Model.metadata(books,1000)==nil,'invalid snapshot was certified')
end
local many={};for i=1,5001 do many[i]={bookId=tostring(i)} end
expect(Model.metadata(many,1000)==nil,'oversized snapshot was certified')
expect(Model.metadata({},1000).book_count==0,'empty snapshot rejected')
expect(Model.metadata({{bookId='42'}},-1).cached_at==0,'invalid local clock was persisted as valid time')
-- The actual SQL statement/transaction also runs in the fast offline suite.
local helper=require('spec.helpers.annotation_test_store')
package.preload['lua-ljsqlite3/init']=function() return {open=helper.connect} end
local DB=require('weread.lib.library_db')
local owner={user_vid=os.tmpname()};local first_owner=owner
local settings={data_dir='/tmp',get=function() return owner end}
local db=DB:new(settings);local first_path=db:databasePath()
expect(db:getShelfStatus('42').present==nil,'fresh database declared absence')
expect(db:putBook({bookId='42',title='Details only'}),'detail setup')
expect(db:getShelfStatus('42').present==nil,'detail row was treated as membership')
expect(db:cacheShelf({{bookId='42',title='Saved shelf',finishReading=0}},{}),'complete snapshot setup')
expect(db:getShelfStatus('42').present==true and db:getShelfStatus('99').present==false,'SQL did not distinguish present and absent')
expect(DB:new(settings):getShelfStatus('99').present==false,'negative evidence did not persist')
expect(db:putBook({bookId='99',finishReading=1}) and db:getShelfStatus('99').present==false,'details overrode absence')
local connection=db:open()
connection:exec([[CREATE TRIGGER stop_membership BEFORE INSERT ON shelf_state
    WHEN NEW.name='membership_snapshot' BEGIN SELECT RAISE(ABORT,'fixture failure'); END]])
connection:close()
expect(not db:cacheShelf({{bookId='99'}},{}),'failed snapshot marker was accepted')
expect(db:getShelfStatus('42').present==true and db:getShelfStatus('99').present==false,'failed marker committed book changes')
connection=db:open();connection:exec('DROP TRIGGER stop_membership');connection:close()
expect(db:cacheShelf({},{}),'empty snapshot setup')
expect(db:getShelfStatus('42').present==false,'empty complete snapshot became unknown')
expect(db:cacheShelf({{bookId='42'}},{}),'legacy setup')
connection=db:open();connection:exec("DELETE FROM shelf_state WHERE name='membership_snapshot'");connection:close()
expect(db:getShelfStatus('42').present==true and db:getShelfStatus('99').present==nil,'legacy cache invented negative evidence')
owner={user_vid=first_owner.user_vid..'-other'};local other_path=db:databasePath()
expect(db:getShelfStatus('42').present==nil,'membership leaked across accounts')
owner=first_owner
expect(db:getShelfStatus('42').present==true,'switching back lost legacy positive evidence')
for _i,path in ipairs({first_path,other_path}) do os.remove(path);os.remove(path..'-wal');os.remove(path..'-shm') end
os.remove(first_owner.user_vid);helper.cleanup()
print(('shelf_membership_snapshot_spec: %d checks'):format(checks))

-- Real synthetic SQLite data; check that both states share one read-only open.
package.path='./?.lua;./?/init.lua;'..package.path
local helper=require('spec.helpers.annotation_test_store')
local opens,read_opens=0,0
package.preload['lua-ljsqlite3/init']=function() return {open=function(path,mode)
    opens=opens+1;if mode=='ro' then read_opens=read_opens+1 end
    return helper.connect(path)
end} end
local account={user_vid=os.tmpname()};os.remove(account.user_vid)
local settings={data_dir='/tmp',get=function(_,key,default) if key=='account' then return account end return default end}
local db=require('weread.lib.library_db'):new(settings)
local first=db:databasePath()
assert(db:putProfileState('statistics',{fetched_at=123,months={}}))
assert(db:putProfileState('goal',{minutes=35}))
assert(db:putProfileState('account_name',{name='Reader',epoch=4}))
local initial=opens
local statistics,goal=db:getHomeProfileState()
assert(opens==initial+1 and read_opens==1 and statistics.fetched_at==123 and goal.minutes==35,
    'home state was not read in one read-only connection')
initial=opens
local name
statistics,goal,name=db:getProfileOverview()
assert(opens==initial+1 and read_opens==2 and statistics.fetched_at==123 and goal.minutes==35
    and name.name=='Reader' and name.epoch==4,'profile overview did not share one read-only connection')
assert(db:putProfileState('goal',{minutes=47}))
statistics,goal=db:getHomeProfileState()
assert(statistics.fetched_at==123 and goal.minutes==47,'home state failed to observe an update')
local connection=db:open()
local statement=connection:prepare('UPDATE profile_state SET payload=? WHERE name=?')
statement:bind('broken payload','statistics'):step();statement:close();connection:close()
statistics,goal,name=db:getProfileOverview()
assert(statistics==nil and goal.minutes==47 and name.name=='Reader','corrupt statistics hid the valid fields')
account={user_vid=account.user_vid..'-other'}
local second=db:databasePath()
assert(db:putProfileState('statistics',{fetched_at=456,months={}}))
statistics,goal,name=db:getProfileOverview()
assert(statistics.fetched_at==456 and goal==nil and name==nil,'profile state leaked across accounts')
account={}
initial=opens;statistics,goal=db:getHomeProfileState()
assert(opens==initial and statistics==nil and goal==nil,'signed-out state opened an account database')
for _,path in ipairs({first,second}) do
    os.remove(path);os.remove(path..'-wal');os.remove(path..'-shm')
end
helper.cleanup()
print('home_profile_state_spec: single read, freshness, corruption and account isolation passed')

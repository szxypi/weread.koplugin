package.path='./?.lua;'..package.path
local opened,closed,prepared=0,0,0
local fail_open,fail_prepare=false,false
package.preload['json']=function() return {decode=function(value)
    if value=='saved-chapter' then return {chapterUid=1,title='cached'} end
end} end
package.preload['lua-ljsqlite3/init']=function() return {open=function(_path,mode)
    opened=opened+1;assert(mode=='ro','catalog lookup opened a writable database')
    if fail_open then error('unavailable') end
    return {close=function() closed=closed+1 end,prepare=function(_db,query)
        prepared=prepared+1;assert(query:find('FROM chapters',1,true))
        if fail_prepare then error('missing schema') end
        local done=false
        local stmt={reset=function(self) return self end,bind=function(self,id) assert(id=='100');return self end,
            close=function() end}
        function stmt:step() if done then return nil end;done=true;return {'saved-chapter'} end
        return stmt
    end}
end} end
local account='42'
local store=require('weread.lib.library_db'):new{data_dir='/synthetic',get=function(_self,key,default)
    if key=='account' then return account and {user_vid=account} or {} end
    return default
end}
local chapters=assert(store:getChapters('100'))
assert(#chapters==1 and chapters[1].title=='cached' and opened==1 and closed==1 and prepared==1)
fail_open=true;assert(not store:getChapters('100') and opened==2 and closed==1)
fail_open=false;fail_prepare=true;assert(not store:getChapters('100') and opened==3 and closed==2)
account=nil;assert(not store:getChapters('100') and opened==3)
print('PASS: account-bound chapter lookup uses a read-only connection')

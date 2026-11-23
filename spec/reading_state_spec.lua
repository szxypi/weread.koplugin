package.path='./?.lua;'..package.path
local calls,answer,current=0,nil,true
package.loaded['weread.lib.native_read_access']={matches=function() return current end}
package.loaded['weread.lib.native_authorization']={new=function(_self,_client,options)
    return {_request=function(_auth,stage,url,body,credentials)
        calls=calls+1
        assert(stage=='reading_state' and body==nil and credentials.accessToken=='private')
        assert(url=='https://i.weread.qq.com/book/getProgress?bookId=CB_abc')
        assert(options.is_current())
        if type(answer)=='string' then error(answer,0) end
        if type(answer)=='function' then return answer() end
        return answer
    end,cancel=function() end}
end}
local Data=require('weread.lib.reading_state')
local function expect(value,message) assert(value,message) end
local owner,id='900001','CB_abc'
expect(Data.id(id)==id and Data.id('42')=='42','eligible identifiers rejected')
for _,value in ipairs({'0','MP_a','CB_a/b','42?x=1','CB_','-1',string.rep('1',21)}) do
    expect(not Data.id(value),'invalid identifier accepted')
end
for _,flag in ipairs({0,1}) do
    local value,reason=Data.project({book={bookId=id,isStartReading=flag}},id,owner)
    expect(not reason and value==(flag==1),'explicit flag decoded incorrectly')
end
local value,reason=Data.project({book={}},id,owner)
expect(value==nil and reason=='missing','missing flag became false')
for _,raw in ipairs({{book={isStartReading=true}},{book={isStartReading='1'}},{book={isStartReading=2}},
    {book={bookId='CB_other',isStartReading=0}},{vid='900002',book={isStartReading=0}},
    {book={userVid='900002',isStartReading=0}},{errcode=-1,book={isStartReading=0}},
    {succ=0,book={isStartReading=0}}, {bookId=9007199254740992,book={isStartReading=0}}}) do
    value,reason=Data.project(raw,id,owner)
    expect(value==nil and reason~='missing','invalid or foreign response accepted')
end
local selected={scope={vid=owner},credentials={accessToken='private'}}
answer={book={isStartReading=0}};local result=Data.read({}, {}, selected,id)
expect(result.kind=='known' and result.started==false and calls==1,'read failed to preserve explicit false')
answer={book={isStartReading=1}};result=Data.read({}, {}, selected,id)
expect(result.kind=='known' and result.started==true and calls==2,'read failed to preserve explicit true')
answer={book={}};expect(Data.read({}, {}, selected,id).kind=='missing','missing field not reported')
answer='native_auth/reading_state/http_401';expect(Data.read({}, {}, selected,id).kind=='login','401 was not classified')
answer='native_auth/reading_state/timeout';expect(Data.read({}, {}, selected,id).kind=='unavailable','timeout was misclassified')
answer=function() current=false;return {book={isStartReading=1}} end
expect(Data.read({}, {}, selected,id).kind=='stale','changed credentials delivered status')
local before=calls
expect(Data.read({}, {}, selected,id).kind=='login' and calls==before,'stale access sent a request')
print('PASS: scoped E-Ink started-reading state')

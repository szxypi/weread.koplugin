-- Real SQLite rollback, quotas, malformed records and account isolation.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local json=require('json');local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local account='900000'
local library=require('weread.lib.library_db'):new{data_dir=root,get=function(_self,key,default) return key=='account' and {user_vid=account} or default end}
local Cache=require('weread.lib.my_cloud_marks_store');local cache=Cache:new(library,codec)
local checks=0
local function expect(value) checks=checks+1;assert(value) end
local function snapshot(id)
    return {schema=1,book_id=id or '900001',fetched_at=1000,updated={{bookmarkId='synthetic-mark',type=1,markText='合成引用',private='strip'}},
        chapters=json.decode('[]'),accessToken='strip'}
end
expect(Cache.MAX_BOOKS==5000)
local projected,saved=cache:writeProjected(snapshot(),'900001')
expect(saved and projected and not projected.accessToken and not projected.updated[1].private)
local foreign,foreign_saved=cache:writeProjected(snapshot('900002'),'900001')
expect(not foreign and not foreign_saved and not cache:read('900002'))
account='900010'
local thoughts=Cache:new(library,codec,'thoughts')
for i=1,130 do
    local id=tostring(940000+i)
    expect(cache:write(snapshot(id),{preserve_existing=true}))
    expect(thoughts:write({schema=1,book_id=id,fetched_at=1000,reviews={{reviewId='synthetic-thought',content='合成想法'}}},
        {preserve_existing=true}))
end
expect(#assert(cache:list_ids())==130 and #assert(thoughts:list_ids())==130)
expect(cache:read('940001')~=nil and cache:read('940130')~=nil
    and thoughts:read('940001')~=nil and thoughts:read('940130')~=nil)
local after_limit=snapshot('940130');after_limit.updated[1].markText='bulk-130-only'
expect(cache:write(after_limit,{preserve_existing=true}))
local catalog={};for i=1,130 do catalog[#catalog+1]={bookId=tostring(940000+i)} end
local search=require('weread.lib.notebook_search').search(catalog,cache,thoughts,'bulk-130-only')
expect(search.checked==260 and search.not_cached==0 and #search.items==1
    and search.items[1].book_id=='940130','cross-book search missed a saved book beyond the old cap')
local valid=assert(cache:valid_ids({'940001','940130','999999'}))
expect(valid['940001'] and valid['940130'] and not valid['999999'])
expect(not cache:valid_ids({'940001','940001'}) and not cache:valid_ids({[1]='940001',[3]='940130'}))
local other=snapshot('940130');other.updated[1].markText='should-not-overwrite'
expect(cache:writeIfMissing(other)=='exists' and cache:read('940130').updated[1].markText=='bulk-130-only')
expect(cache:writeIfMissing(snapshot('940131'))==true and cache:writeIfMissing(snapshot('940131'))=='exists')
local db130=assert(library:open());local raw130=db130:rowexec("SELECT payload FROM my_cloud_marks WHERE book_id='940130'")
db130:close()
local function replace130(payload)
    local db=assert(library:open());local stmt=db:prepare('UPDATE my_cloud_marks SET payload=? WHERE book_id=?')
    stmt:bind(payload,'940130'):step();stmt:close();db:close()
end
local invalid_utf8=raw130:gsub('bulk%-130%-only','bad-\237\160\128')
assert(invalid_utf8~=raw130)
for _,damaged in ipairs({'{}',invalid_utf8}) do
    replace130(damaged)
    expect(cache:valid_ids({'940130'})==nil and cache:writeIfMissing(other)==nil and cache:read('940130')==nil)
end
replace130(raw130)
expect(cache:read('940130').updated[1].markText=='bulk-130-only')
account='900011'
local empty=assert(cache:valid_ids({'940001'}));expect(not next(empty))
local fresh=assert(library:open());fresh:close()
empty=assert(cache:valid_ids({'940001'}));expect(not next(empty))
account='900000';Cache.MAX_BOOKS=64 -- Exercise both quota boundaries with a small fixture.
expect(cache:write(snapshot()));expect(cache:read('900001').updated[1].markText=='合成引用')
projected,saved=cache:writeProjected(snapshot('CB_SyntheticNotes'),'CB_SyntheticNotes')
expect(saved and projected and projected.book_id=='CB_SyntheticNotes')
expect(cache:read('CB_SyntheticNotes').updated[1].markText=='合成引用')
local ids=assert(cache:list_ids());expect(#ids==2 and ids[1]=='CB_SyntheticNotes' and ids[2]=='900001')
local db=assert(library:open());local raw=db:rowexec("SELECT payload FROM my_cloud_marks WHERE book_id='900001'");db:close();expect(not raw:find('strip',1,true))
account='900099';expect(cache:read('900001')==nil and cache:read('CB_SyntheticNotes')==nil and #assert(cache:list_ids())==0);account='900000'
local open=library.open
function library:open()
    local handle=assert(open(self))
    return {exec=function(_self,sql) if sql=='COMMIT' then error('synthetic commit failure') end;return handle:exec(sql) end,
        prepare=function(_self,sql) return handle:prepare(sql) end,close=function() return handle:close() end}
end
local changed=snapshot();changed.updated[1].markText='unsaved'
expect(not cache:write(changed))
projected,saved=cache:writeProjected(changed,'900001')
expect(projected and projected.updated[1].markText=='unsaved' and not saved)
library.open=open;expect(cache:read('900001').updated[1].markText=='合成引用')
-- If the aggregate cannot provide totals, retain the ordered quota scan.
local quota_queries=0
function library:open()
    local handle=assert(open(self))
    return {exec=function(_,sql) return handle:exec(sql) end,close=function() return handle:close() end,
        prepare=function(_,sql)
            if sql:find('SELECT COUNT(*),COALESCE(SUM(',1,true) then
                quota_queries=quota_queries+1
                local blank={};blank.bind=function(stmt) return stmt end;blank.step=function() return nil end;blank.close=function() end
                return blank
            end
            return handle:prepare(sql)
        end}
end
expect(cache:write(snapshot()) and quota_queries==1);library.open=open
expect(cache:read('900001').updated[1].markText=='合成引用')
local oversized=snapshot();oversized.updated={}
for i=1,33 do oversized.updated[i]={bookmarkId='synthetic-'..i,markText=string.rep('x',131072)} end
expect(not cache:write(oversized) and cache:read('900001').updated[1].markText=='合成引用')
projected,saved=cache:writeProjected(oversized,'900001')
expect(projected and not saved and cache:read('900001').updated[1].markText=='合成引用')
for i=1,65 do expect(cache:write(snapshot(tostring(910000+i)))) end
expect(cache:read('910001')==nil and cache:read('910065')~=nil)
db=library:open();expect(tonumber(db:rowexec('SELECT COUNT(*) FROM my_cloud_marks'))==64)
expect(not cache:write(snapshot('930001'),{preserve_existing=true}))
expect(cache:read('930001')==nil and cache:read('910002')~=nil and cache:read('910065')~=nil)
local kept=snapshot('910002');kept.updated[1].markText='refreshed'
expect(cache:write(kept,{preserve_existing=true}) and cache:read('910002').updated[1].markText=='refreshed')
expect(not cache:write(snapshot('930001'),{preserve_existing=false}) and cache:read('930001')==nil)
db:exec("UPDATE my_cloud_marks SET payload='{}' WHERE book_id='910065'");db:close();expect(cache:read('910065')==nil)
-- Use actual near-limit snapshots to check the aggregate payload bound.
oversized=snapshot();oversized.updated={}
for i=1,30 do oversized.updated[i]={bookmarkId='synthetic-'..i,markText=string.rep('x',131072)} end
for i=1,10 do oversized.book_id=tostring(920000+i);expect(cache:write(oversized)) end
db=library:open();expect(tonumber(db:rowexec('SELECT SUM(length(CAST(payload AS BLOB))) FROM my_cloud_marks'))<=Cache.MAX_TOTAL);db:close()
expect(cache:read('920001')==nil and cache:read('920010')~=nil)
oversized.book_id='930002'
expect(not cache:write(oversized,{preserve_existing=true}))
expect(cache:writeIfMissing(oversized)==nil and cache:read('930002')==nil and cache:read('920010')~=nil)
print('PASS: own cloud marks SQLite ('..checks..' checks)')

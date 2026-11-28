-- Synthetic SQLite comparison against the pre-optimization store.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local baseline=assert(loadfile(assert(arg[2])))()
local root=assert(arg[3]);assert(root:match('^/dev/shm/'))
local current=require('weread.lib.my_cloud_marks_store')
local json=require('json');local lfs=require('libs/libkoreader-lfs')
local codec={json_encode=function(_,value) return json.encode(value) end,
    json_decode=function(_,value) return json.decode(value) end}
local function library(name)
    local path=root..'/'..name;assert(lfs.mkdir(path))
    return require('weread.lib.library_db'):new{data_dir=path,get=function(_,key,default)
        return key=='account' and {user_vid='900000'} or default
    end}
end
local function snapshot(id,variant,revision,size)
    local text=string.rep('x',size or 32)
    if variant=='thoughts' then
        return {schema=1,book_id=id,fetched_at=1000+revision,reviews={{reviewId='synthetic',content=text}}}
    end
    return {schema=1,book_id=id,fetched_at=1000+revision,
        updated={{bookmarkId='synthetic',type=1,markText=text}},chapters=json.decode('[]')}
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function exercise(variant)
    local kind=variant=='thoughts' and 'thoughts' or nil
    local old=baseline:new(library('diff-old-'..variant),codec,kind)
    local new=current:new(library('diff-new-'..variant),codec,kind)
    baseline.MAX_BOOKS,current.MAX_BOOKS=8,8
    baseline.MAX_TOTAL,current.MAX_TOTAL=2400,2400
    local seed=snapshot('100000',variant,0,64)
    assert(old:writeIfMissing(seed)==true and new:writeIfMissing(seed)==true)
    assert(old:writeIfMissing(seed)=='exists' and new:writeIfMissing(seed)=='exists')
    local rejected,evicted=0,0
    for index=1,120 do
        local previous=assert(old:list_ids())
        local id=tostring(100000+(index*17)%13)
        local value=snapshot(id,variant,index,40+(index*37)%500)
        local a,b
        if index%5==0 then a,b=old:writeIfMissing(value),new:writeIfMissing(value)
        elseif index%3==0 then a,b=old:write(value,{preserve_existing=true}),new:write(value,{preserve_existing=true})
        else a,b=old:write(value),new:write(value) end
        assert(a==b,'write outcome changed')
        if not a then rejected=rejected+1 end
        local ids=assert(old:list_ids());assert(equal(ids,new:list_ids()),'eviction order changed')
        local retained={};for _,book in ipairs(ids) do retained[book]=true end
        for _,book in ipairs(previous) do if not retained[book] then evicted=evicted+1 end end
        for _,book in ipairs(ids) do assert(equal(old:read(book),new:read(book)),'stored snapshot changed') end
    end
    assert(rejected>0 and evicted>0,'comparison missed quota rejection or eviction')
end
exercise('marks');exercise('thoughts')
baseline.MAX_BOOKS,current.MAX_BOOKS=5000,5000
baseline.MAX_TOTAL,current.MAX_TOTAL=32*1024*1024,32*1024*1024
local function sample(store_module,variant,n,name)
    local kind=variant=='thoughts' and 'thoughts' or nil
    local db_library=library(name);local store=store_module:new(db_library,codec,kind)
    local first=snapshot('100001',variant,0);assert(store:write(first))
    local db=assert(db_library:open());local tab=variant=='marks' and 'my_cloud_marks' or 'my_cloud_thoughts'
    db:exec('BEGIN IMMEDIATE');db:exec('DELETE FROM '..tab)
    local stmt=db:prepare('INSERT INTO '..tab..'(book_id,payload,serial) VALUES(?,?,?)')
    for i=1,n do
        local id=tostring(100000+i)
        stmt:reset():bind(id,codec:json_encode(snapshot(id,variant,0)),i):step()
    end
    stmt:close();db:exec('COMMIT');db:close()
    local target=tostring(100000+math.floor(n/2));local started=os.clock()
    for i=1,20 do assert(store:write(snapshot(target,variant,i))) end
    local cpu_ms=(os.clock()-started)*1000
    assert(store:read(target).fetched_at==1020)
    -- Count rows crossing the SQLite/Lua boundary in one additional write.
    local original_open=db_library.open;local rows=0
    function db_library.open(lib)
        local inner=assert(original_open(lib));local wrapper={}
        wrapper.exec=function(_,sql) return inner:exec(sql) end
        wrapper.close=function() return inner:close() end
        wrapper.prepare=function(_,sql)
            local inner_stmt=inner:prepare(sql)
            if not sql:find('SELECT book_id,length(CAST(payload AS BLOB)) FROM',1,true) then return inner_stmt end
            local wrapped={}
            wrapped.bind=function(receiver,...) inner_stmt:bind(...);return receiver end
            wrapped.step=function() rows=rows+1;return inner_stmt:step() end
            wrapped.close=function() return inner_stmt:close() end
            return wrapped
        end
        return wrapper
    end
    assert(store:write(snapshot(target,variant,21)))
    return {cpu_ms=cpu_ms,ordered_row_steps=rows}
end
local measurements={}
for _,variant in ipairs({'marks','thoughts'}) do
    for _,n in ipairs({140,1200,5000}) do
        local old=sample(baseline,variant,n,'old-'..variant..'-'..n)
        local new=sample(current,variant,n,'new-'..variant..'-'..n)
        assert(old.ordered_row_steps==n+1 and new.ordered_row_steps==0,'unexpected quota fast-path steps')
        measurements[#measurements+1]={variant=variant,books=n,old=old,new=new,iterations=20}
    end
end
print('WEREAD_PERSONAL_CACHE_BENCHMARK='..json.encode{result='PASS',differential_operations=240,measurements=measurements})

-- Compare the old two-validation reader path with one validated cache write.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'))
local json=require('json');local lfs=require('libs/libkoreader-lfs')
local codec={json_encode=function(_,value) return json.encode(value) end,json_decode=function(_,value) return json.decode(value) end}
local Store=require('weread.lib.my_cloud_marks_store')
local function library(name)
    local path=root..'/'..name;assert(lfs.mkdir(path))
    return require('weread.lib.library_db'):new{data_dir=path,get=function(_,key,default)
        return key=='account' and {user_vid='900000'} or default
    end}
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for key,value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function snapshot(kind,n)
    local result={schema=1,book_id='900001',fetched_at=1000,token='discard'}
    if kind=='marks' then result.updated=json.decode('[]');result.chapters=json.decode('[]')
    else result.reviews=json.decode('[]') end
    for i=1,n do
        if kind=='marks' then
            result.updated[i]={bookmarkId='synthetic-'..i,type=1,markText='合成文字 '..i,range='1-9',private='discard'}
        else
            result.reviews[i]={reviewId='synthetic-'..i,content='合成想法 '..i,abstract='合成文字',isPrivate=1,userVid='discard'}
            if i%7==0 then
                local row=result.reviews[i]
                row.attachment_state=i%14==0 and 'partial' or 'available'
                row.attachment_urls=i%14==0 and '' or 'https://weread-picture-1258476243.file.myqcloud.com/synthetic.png'
                row.attachment_digest=string.rep('a',64)
            end
        end
    end
    return result
end
local function sample(kind,n,mode)
    local variant=kind=='thoughts' and 'thoughts' or nil
    local data=require(kind=='thoughts' and 'weread.lib.my_cloud_thoughts' or 'weread.lib.my_cloud_marks')
    local store=Store:new(library(mode..'-'..kind..'-'..n),codec,variant)
    local raw=snapshot(kind,n)
    for _=1,3 do
        if mode=='old' then assert(store:write(data.validate(codec,raw,raw.book_id)))
        else local _,saved=store:writeProjected(raw,raw.book_id);assert(saved) end
    end
    local calls=0;local validate=data.validate
    data.validate=function(...) calls=calls+1;return validate(...) end
    local result;local start=os.clock()
    for _=1,10 do
        if mode=='old' then
            result=data.validate(codec,raw,raw.book_id);assert(store:write(result))
        else
            local saved;result,saved=store:writeProjected(raw,raw.book_id);assert(saved)
        end
    end
    local cpu_ms=(os.clock()-start)*1000;data.validate=validate
    assert(calls==(mode=='old' and 20 or 10),'unexpected validation count')
    assert(not result.token and same(result,store:read(raw.book_id)),'persisted projection changed')
    return {cpu_ms=cpu_ms,validation_calls=calls,snapshot=result}
end
local measurements={}
for _,kind in ipairs({'marks','thoughts'}) do
    for _,n in ipairs({50,500,2000}) do
        local old=sample(kind,n,'old');local new=sample(kind,n,'new')
        assert(same(old.snapshot,new.snapshot),'new projection differs from prior reader path')
        old.snapshot=nil;new.snapshot=nil
        measurements[#measurements+1]={variant=kind,notes=n,iterations=10,old=old,new=new}
    end
end
print('WEREAD_PERSONAL_PROJECTION_BENCHMARK='..json.encode{result='PASS',measurements=measurements})

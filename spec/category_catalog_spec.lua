package.path='./?.lua;'..package.path
local Catalog=require('weread.lib.category_catalog')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function invalid(task) local ok,err=pcall(task);expect(not ok and tostring(err):match('^category_catalog/'),'invalid hierarchy accepted') end
local source={data={{categories={{CategoryId='rising',title='Rising'},{CategoryId='100',title='Literature',sublist={{categoryId='101',title='Fiction'}}},
    {CategoryId='audio',title='Audio',type=1},{CategoryId='../invalid',title='Invalid'},{CategoryId='rising',title='Duplicate'}}}}}
local value=Catalog.project(source,1000)
expect(value.schema==1 and #value.ranks==1 and #value.categories==1 and value.categories[1].children[1].id=='101','hierarchy/rank/filtering lost')
value.cookies='discarded';value.ranks[1].private='discarded'
expect(Catalog.validate(value,1000).cookies==nil and Catalog.validate(value,1000).ranks[1].private==nil,'snapshot retained extra fields')
for _,bad in ipairs({{}, {data={}}, {data={wrong=true}}, {data=source.data,errCode=-1}, {data=source.data,succ=false},
    {data={{CategoryId='100',title=true}}}, {data={{CategoryId='100',title='bad\nlabel'}}},
    {data={{CategoryId='100',title=string.rep('x',4097)}}}, {data={{categories={wrong=true}}}}}) do
    invalid(function() Catalog.project(bad,1000) end)
end
local cyclic={};cyclic[1]={categories=cyclic};invalid(function() Catalog.project({data=cyclic},1000) end)
local many={};for i=1,Catalog.MAX_NODES+1 do many[i]=false end
invalid(function() Catalog.project({data=many},1000) end)
for _,change in ipairs({'nonfinite','timestamp','rank','id','children','cycle'}) do
    local copy=Catalog.project(source,1000)
    if change=='nonfinite' then copy.loaded_at=math.huge
    elseif change=='timestamp' then copy.loaded_at=1000.1
    elseif change=='rank' then copy.categories[1].rank=true
    elseif change=='id' then copy.ranks[1].id='../bad'
    elseif change=='children' then copy.categories[1].children={wrong=true}
    else copy.categories[1].children=copy.categories end
    invalid(function() Catalog.validate(copy,1000) end)
end
local future=Catalog.project(source,os.time()+3600)
expect(Catalog.validate(future).categories[1].id=='100','clock rollback discarded public cached labels')
-- Simulated failures verify descriptor cleanup and preserve existing cache.
-- Real SQLite roundtrip, corruption and guest use are covered in native smoke.
local state={closed=0,statements=0,payloads={}}
package.preload['lua-ljsqlite3/init']=function() return {open=function(path)
    state.path=path
    if state.open_error then error('private path failure') end
    return {close=function() state.closed=state.closed+1 end,
        exec=function() if state.schema_error then error('private schema failure') end end,
        prepare=function(_self,sql)
            local stmt={}
            function stmt:bind(...) self.args={...};return self end
            function stmt:close() state.statements=state.statements+1 end
            function stmt:step()
                if state.step_error then error('private SQLite failure') end
                if sql:find('SELECT',1,true) then return state.row end
                state.row={self.args[1],self.args[2]}
            end
            return stmt
        end}
end} end
local codec={json_encode=function(_self,snapshot)
    if state.encode_error then error('private encode failure') end
    local text=state.large and string.rep('x',Catalog.MAX_PAYLOAD+1) or 'payload'..(#state.payloads+1)
    state.payloads[text]=snapshot;return text
end,json_decode=function(_self,text) return assert(state.payloads[text]) end}
local store=Catalog:new({data_dir='/synthetic'},codec)
expect(store:write(value) and state.path=='/synthetic/bookstore-public.db','public cache needed account or changed path')
expect(store:read().categories[1].id=='100','stored hierarchy did not roundtrip')
local kept=state.row
state.encode_error=true;expect(not store:write(value) and state.row==kept,'encoding failure replaced cache');state.encode_error=false
state.large=true;expect(not store:write(value) and state.row==kept,'oversized payload replaced cache');state.large=false
for _,failure in ipairs({'schema_error','step_error','open_error'}) do
    state[failure]=true
    local before=state.closed
    expect(not store:write(value) and not store:read() and state.row==kept,failure..' accepted or replaced cache')
    expect(state.closed==before+(failure=='open_error' and 0 or 2),failure..' leaked database handle')
    state[failure]=false
end
state.row={'corrupt',1000};expect(store:read()==nil,'corrupt JSON accepted')
state.row={kept[1],1001};expect(store:read()==nil,'mismatched stored timestamp accepted')
state.row={string.rep('x',Catalog.MAX_PAYLOAD+1),1000};expect(store:read()==nil,'oversized stored payload accepted')
expect(state.closed>0 and state.statements>0,'cache descriptors were not closed')
print('PASS: public category catalog ('..checks..' checks)')

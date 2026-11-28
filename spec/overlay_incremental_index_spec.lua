package.path='./?.lua;'..package.path
local Overlay=require('weread.ui.xpointer_overlay')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function run(pattern)
    local comparisons=0
    local doc={getCurrentPos=function() return 250 end,getCurrentPage=function() return 250 end,
        getPageCount=function() return 600 end,getVisiblePageCount=function() return 1 end,
        getPageXPointer=function(_,page) return page end,
        compareXPointers=function(_,a,b) comparisons=comparisons+1;return a==b and 0 or a<b and 1 or -1 end,
        getPosFromXPointer=function(_,xp) return xp end,
        getScreenBoxesFromPositions=function(_,a) return {{x=a,y=0,w=1,h=1}} end}
    local records={}
    local function layer()
        local value=Overlay:new{};value.ui={document=doc,dimen={h=1}};value.view={view_mode='page'};return value
    end
    local incremental,full=layer(),layer()
    incremental:setRecords(records,true)
    local incremental_comparisons,full_comparisons=0,0
    for batch=1,64 do
        local earliest
        for offset=1,8 do
            local n=(batch-1)*8+offset
            local start=pattern=='append' and n or pattern=='prepend' and 513-n or (n*193)%512+1
            local row={id=n,pos0=start,pos1=start+(n%13==0 and 25 or .5)}
            local at=1
            while records[at] and records[at].pos0<=row.pos0 do at=at+1 end
            table.insert(records,at,row);earliest=math.min(earliest or at,at)
        end
        incremental:setRecords(records,true,earliest)
        local copy={};for i,row in ipairs(records) do copy[i]=row end
        full:setRecords(copy,true)
        comparisons=0;local a=incremental:_computeVisible();incremental_comparisons=incremental_comparisons+comparisons
        comparisons=0;local b=full:_computeVisible();full_comparisons=full_comparisons+comparisons
        expect(#a==#b,'incremental results changed')
        for i,entry in ipairs(a) do expect(entry.record==b[i].record,'overlap order changed') end
    end
    if pattern=='append' then
        expect(incremental_comparisons<full_comparisons/3,'append batches did not reuse the prefix')
        local prefix=incremental._ordered_prefix_ends
        for i=513,520 do records[i]={id=i,pos0=i,pos1=i+.5} end
        incremental:setRecords(records,true,513)
        for i=521,528 do records[i]={id=i,pos0=i,pos1=i+.5} end
        incremental:setRecords(records,true,521)
        expect(incremental._ordered_prefix_ends==prefix,'unpainted append batches lost the retained prefix')
        local copy={};for i,row in ipairs(records) do copy[i]=row end
        full:setRecords(copy,true)
        local a,b=incremental:_computeVisible(),full:_computeVisible()
        expect(#a==#b,'unpainted append batches changed results')
        for i,entry in ipairs(a) do expect(entry.record==b[i].record,'unpainted append changed overlap order') end
    end
    -- An untrusted update with no insertion boundary must rebuild the prefix.
    records[1].pos1=599
    incremental:setRecords(records,true)
    local actual=incremental:_computeVisible()
    local copy={};for i,row in ipairs(records) do copy[i]=row end
    full:setRecords(copy,true);local expected=full:_computeVisible()
    expect(#actual==#expected and actual[1].record==expected[1].record,'full update retained a stale prefix')
    -- Prefixes must never migrate to another native document.
    local next_doc={};for key,value in pairs(doc) do next_doc[key]=value end
    incremental.ui.document=next_doc;incremental:_computeVisible()
    expect(incremental._ordered_prefix_document==next_doc,'prefix was reused for another document')
end
run('append');run('prepend');run('mixed')
print(('overlay_incremental_index_spec: %d checks'):format(checks))

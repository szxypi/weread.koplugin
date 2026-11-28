-- Compare incremental and complete highlight-index rebuilds using native DOM.
return function(reader,flush,baseline_path,options)
    options=options or {}
    local document=reader.document
    local total=document:getPageCount();assert(total>=(options.min_pages or 8))
    local source={}
    for page=1,total do
        local start=document:getPageXPointer(page)
        for _=1,math.max(5,math.ceil(50/total)) do
            start=start and document:getNextVisibleChar(start)
            local finish=start and document:getNextVisibleChar(start)
            if finish and document:compareXPointers(start,finish)==1 then
                source[#source+1]={pos0=start,pos1=finish}
            end
        end
    end
    assert(#source>=32,'not enough native points')
    table.sort(source,function(a,b) return document:compareXPointers(a.pos0,b.pos0)==1 end)
    local records_source={}
    for i=1,320 do
        local row=source[(i-1)%#source+1]
        local finish=row.pos1
        if i%11==0 then
            local later=source[math.min(#source,(i-1)%#source+4)]
            if document:compareXPointers(row.pos0,later.pos1)==1 then finish=later.pos1 end
        end
        records_source[#records_source+1]={id=i,pos0=row.pos0,pos1=finish}
    end
    table.sort(records_source,function(a,b)
        local order=document:compareXPointers(a.pos0,b.pos0)
        return order==1 or order==0 and a.id<b.id
    end)
    reader.rolling:onGotoPage(math.floor(total/2));flush()
    local Optimized=require('weread.ui.xpointer_overlay')
    local Original=assert(loadfile(baseline_path))()
    local comparisons=0
    local original_compare=document.compareXPointers;local own=rawget(document,'compareXPointers')
    document.compareXPointers=function(self,a,b) comparisons=comparisons+1;return original_compare(self,a,b) end
    local function equal(a,b)
        if #a~=#b then return false end
        for i,entry in ipairs(a) do
            local other=b[i]
            if entry.record~=other.record then return false end
            for _,field in ipairs({'x','y','w','h'}) do if entry.rect[field]~=other.rect[field] then return false end end
        end
        return true
    end
    local results={}
    for _,pattern in ipairs({'append','prepend','mixed'}) do
        local rows={}
        local current=Optimized:new{};current.ui=reader;current.view=reader.view;current:setRecords(rows,true)
        local previous=Original:new{};previous.ui=reader;previous.view=reader.view;previous:setRecords(rows,true)
        local old_count,new_count=0,0
        for batch=1,40 do
            local earliest
            for offset=1,8 do
                local n=(batch-1)*8+offset
                local i=pattern=='append' and n or pattern=='prepend' and 321-n or (n*193)%320+1
                local row=records_source[i]
                local at=1
                while rows[at] do
                    local order=original_compare(document,rows[at].pos0,row.pos0)
                    if order==-1 or order==0 and rows[at].id>row.id then break end
                    at=at+1
                end
                table.insert(rows,at,row);earliest=math.min(earliest or at,at)
            end
            current:setRecords(rows,true,earliest);previous:setRecords(rows,true)
            comparisons=0;local a=current:_computeVisible();new_count=new_count+comparisons
            comparisons=0;local b=previous:_computeVisible();old_count=old_count+comparisons
            assert(equal(a,b),'incremental native boxes differ from a complete rebuild')
        end
        results[pattern]={before=old_count,after=new_count}
    end
    document.compareXPointers=own
    assert(results.append.after<results.append.before*(options.max_append_ratio or 1/3),
        'append index did not reuse native comparisons')
    reader.rolling:onGotoPage(1);flush()
    return {records=320,batches=40,source_points=#source,comparisons=results}
end

-- Cross-check the prefilter against native visibility on a synthetic EPUB.
return function(reader,flush,options)
    options=options or {}
    local document=reader.document
    local total=document:getPageCount()
    assert(total>=(options.min_pages or 8),'fixture has too few pages for index comparison')
    assert(document:getVisiblePageCount()==1 and not document:hasNonLinearFlows(),'fixture is not single-page linear EPUB')
    local records={}
    for page=1,total do
        local xp=document:getPageXPointer(page)
        for _=1,math.max(5,math.ceil(50/total)) do
            xp=xp and document:getNextVisibleChar(xp)
            if xp then records[#records+1]={pos0=xp,bookmarkId='synthetic-'..#records} end
        end
    end
    assert(#records>=32,'fixture has too few source positions')
    local indicator=require('weread.ui.bookmark_indicator'):new{color=0}
    indicator.ui=reader;indicator.view=reader.view;indicator:setRecords(records)
    indicator.geometry=function() return {x=1,y=1,w=12,h=18} end
    local original=require('weread.ui.bookmark_indicator'):new{color=0,allow_page_index=false}
    original.ui=reader;original.view=reader.view;original:setRecords(records);original.geometry=indicator.geometry
    local base=document.isXPointerInCurrentPage;local own=rawget(document,'isXPointerInCurrentPage')
    local page_map=document.getPageFromXPointer;local own_page_map=rawget(document,'getPageFromXPointer')
    local queries,indicator_queries,baseline_queries,map_queries,index_maps=0,0,0,0,0
    document.isXPointerInCurrentPage=function(self,xp) queries=queries+1;return base(self,xp) end
    document.getPageFromXPointer=function(self,xp) map_queries=map_queries+1;return page_map(self,xp) end
    local painted
    local canvas={paintRect=function(_,x,y,w,h) painted[#painted+1]=table.concat({x,y,w,h},':') end}
    local function check_pages()
        for page=1,document:getPageCount() do
            reader.rolling:onGotoPage(page);flush()
            local expected={}
            for _,row in ipairs(records) do if base(document,row.pos0) then expected[#expected+1]=row end end
            local before,prior_maps=queries,map_queries;painted={};indicator:paintTo(canvas,0,0)
            indicator_queries=indicator_queries+queries-before;index_maps=index_maps+map_queries-prior_maps
            local actual=table.concat(painted,';');before=queries;painted={};original:paintTo(canvas,0,0)
            baseline_queries=baseline_queries+queries-before
            assert(indicator.page_index,'native page prefilter was not active')
            assert(#indicator.visible==#expected,'native bookmark count changed')
            for i,row in ipairs(expected) do assert(indicator.visible[i]==row,'native bookmark order changed') end
            assert(actual==table.concat(painted,';'),'native bookmark drawing changed')
        end
    end
    check_pages()
    local before_reflow=indicator.page_index
    local font=reader.font.configurable.font_size
    reader.font:onSetFontSize(font+4);flush()
    local reflow_pages=document:getPageCount()
    if reflow_pages==total then reader.font:onSetFontSize(font+10);flush();reflow_pages=document:getPageCount() end
    assert(reflow_pages~=total,'font change did not repaginate fixture')
    check_pages()
    assert(indicator.page_index~=before_reflow,'reflow reused the previous page index')
    reader.font:onSetFontSize(font);flush()
    document.isXPointerInCurrentPage=own;document.getPageFromXPointer=own_page_map
    assert(baseline_queries==#records*(total+reflow_pages),'baseline did not scan every bookmark')
    assert(indicator_queries+index_maps<baseline_queries,'native page prefilter did not reduce checks')
    reader.rolling:onGotoPage(1);flush()
    return {pages=total,reflow_pages=reflow_pages,points=#records,native_checks=indicator_queries,
        page_map_checks=index_maps,full_scan_checks=baseline_queries}
end

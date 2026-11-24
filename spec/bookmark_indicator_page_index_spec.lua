package.path='./?.lua;'..package.path
local Indicator=require('weread.ui.bookmark_indicator')
local current,total,spread,hash=1,100,1,10
local scans,maps,extended_hash=0,0,false
local mismatch,nonlinear,broken=false,false,false
local document={
    getPageMargins=function() return {top=30,right=30} end,getHeaderHeight=function() return 0 end,
    getCurrentPage=function() return current end,getPageCount=function() return total end,
    getVisiblePageCount=function() return spread end,getCurrentPos=function() return current*100 end,
    getPageXPointer=function(_,n) return 'anchor-'..n end,
    getDocumentRenderingHash=function(_,extended) extended_hash=extended;return hash end,
    hasNonLinearFlows=function() return nonlinear end,
    getPageFromXPointer=function(_,xp)
        maps=maps+1
        if xp=='unknown' then return nil end
        local n=tonumber(xp:match('%d+'))
        if mismatch and xp:match('^anchor') then return n+5 end
        if broken then error('unavailable') end
        return n
    end,
    isXPointerInCurrentPage=function(_,xp)
        scans=scans+1
        if xp=='unknown' then return current==50 end
        return tonumber(xp:match('%d+'))==current
    end,
}
local layer=Indicator:new{color=0}
layer.ui={document=document,dimen={w=600,h=800}};layer.view={view_mode='page'}
local rows={}
for i=1,1000 do rows[i]={bookmarkId=tostring(i),pos0='point-'..((i*37)%total+1)} end
rows[1001]={bookmarkId='unknown',pos0='unknown'}
layer:setRecords(rows)
local canvas={paintRect=function() end}
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function verify()
    layer:paintTo(canvas,0,0)
    local expected={}
    for _,row in ipairs(rows) do
        local found=row.pos0=='unknown' and current==50
            or row.pos0~='unknown' and tonumber(row.pos0:match('%d+'))==current
        if found then expected[#expected+1]=row end
    end
    expect(#layer.visible==#expected,'visible count differs')
    for i,row in ipairs(expected) do expect(layer.visible[i]==row,'bookmark ordering differs') end
end
for page=1,total do current=page;verify() end
expect(extended_hash==true,'layout identity omitted the extended rendering hash')
expect(scans<4000,'indexed pages checked too many bookmarks')
expect(maps<=201,'duplicate pointers were remapped')
current=100;local old=scans;verify();expect(scans==old,'recent page was not cached')
-- A new rendering hash may change pagination even if total pages and viewport
-- bounds happen to stay the same. Previous cached pages and index must go.
hash=11;local old_index=layer.page_index;verify()
expect(layer.page_index~=old_index and maps>201,'layout change reused the old index')
nonlinear=true;scans=0;verify()
expect(scans==#rows and not layer.page_index,'nonlinear layout did not scan all bookmarks')
nonlinear=false;spread=2;layer:invalidate();scans=0;verify()
expect(scans==#rows and not layer.page_index,'spread did not scan all bookmarks')
spread=1;mismatch=true;layer:invalidate();scans=0;verify()
expect(scans==#rows and not layer.page_index,'incompatible page numbering was used')
mismatch=false;broken=true;layer:invalidate();scans=0;verify()
expect(scans==#rows and not layer.page_index,'failed page mapping did not scan all bookmarks')
layer:invalidate();broken=false;verify();local first=layer.page_index
layer:setRecords(rows);verify();expect(layer.page_index~=first,'record update reused stale index')
-- While the controller is adding batches, keep the original scan instead of
-- rebuilding a growing index on every batch; build it after loading finishes.
layer:invalidate();layer.allow_page_index=false;scans=0;maps=0
for page=1,4 do current=page;verify() end
expect(scans==4*#rows and maps==0 and not layer.page_index,'incomplete batch built an index')
layer.allow_page_index=true;current=5;verify()
expect(layer.page_index and maps>0,'completed batch did not enable the index')
print(('bookmark_indicator_page_index_spec: %d checks'):format(checks))

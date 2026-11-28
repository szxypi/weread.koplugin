package.path='./?.lua;'..package.path
local Indicator=require('weread.ui.bookmark_indicator')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local page,screen_y,screen_x=1,0,20
local margins={top=30,right=30};local calls={}
local doc={getPageMargins=function() return margins end,getHeaderHeight=function() return 15 end,
    isXPointerInCurrentPage=function(_self,xp) if xp=='bad' then error('invalid point') end;return xp==page end,
    getScreenPositionFromXPointer=function() return screen_y,screen_x end}
local notes={{text='native'}}
local ui={dimen={w=600,h=800},document=doc,annotation={annotations=notes}}
local view={view_mode='page',dogear_visible=false,dogear={dogear_size=20},footer={getHeight=function() return 30 end}}
local layer=Indicator:new{color=0};layer.ui=ui;layer.view=view
local bb={paintRect=function(_self,x,y,w,h) expect(w>0 and h>0 and x>=0 and y>=0);calls[#calls+1]={x=x,y=y,w=w,h=h} end}
local first={bookmarkId='first',pos0=1};local second={bookmarkId='second',pos0=2}
layer:setRecords({{pos0='bad'},first,second});layer:paintTo(bb,0,0)
expect(#layer.visible==1 and layer.visible[1]==first and layer.rect.y==17,'page membership/invalid point handling failed')
local r=layer.rect;expect(layer:hitTest{x=r.x+1,y=r.y+1}==first)
local same_page={bookmarkId='same-page',pos0=1}
layer:setRecords({first,same_page,first,second});layer:paintTo(bb,0,0);r=layer.rect
local hits=layer:hitTestAll{x=r.x+1,y=r.y+1}
expect(#hits==2 and hits[1]==first and hits[2]==same_page,'same-page bookmarks were not returned independently')
expect(not layer:hitTest{x=r.x+r.w,y=r.y},'half-open right edge is active')
page=2;expect(not layer:hitTest{x=r.x+1,y=r.y+1} and #layer:hitTestAll{x=r.x+1,y=r.y+1}==0,'stale painted page is clickable')
layer:paintTo(bb,0,0);expect(layer.visible[1]==second)
page=3;layer:paintTo(bb,0,0);expect(#layer.visible==0 and not layer.rect,'unbookmarked page retained corner')
page=1;view.dogear_visible=true;layer:paintTo(bb,0,0)
expect(layer.rect.y==37 and view.dogear_visible and view.dogear.dogear_size==20,'native dogear changed/overlapped')
margins.right=0;layer:paintTo(bb,0,0);expect(layer.rect.x==564 and layer.rect.y==17,'top margin fallback overlapped native dogear')
margins.top=0;layer:paintTo(bb,0,0);expect(not layer.rect and #layer.visible==0,'corner overwrites text without margins')
margins={top=30,right=30};view.view_mode='scroll';view.dogear_visible=false
local regular=margins;margins={top=15,right=10}
layer:setRecords({first});layer:paintTo(bb,0,0)
expect(layer.rect and layer.rect.w==8 and layer.rect.h==12 and layer.rect.x>=590,'default narrow native margin lost corner')
margins=regular
layer:setRecords({first});layer:paintTo(bb,4,6);r=layer.rect
expect(r.x==590 and r.y==8 and layer:hitTest{x=r.x+1,y=r.y+1}==first,'paint origin/hit rectangle mismatch')
view.footer_visible=true;screen_y=769;layer:paintTo(bb,0,0);expect(layer.rect~=nil)
for _i,y in ipairs({-1,770,799,800}) do screen_y=y;layer:paintTo(bb,0,0);expect(not layer.rect,'offscreen/footer point visible') end
screen_y=0;screen_x=-1;layer:paintTo(bb,0,0);expect(not layer.rect)
screen_x=600;layer:paintTo(bb,0,0);expect(not layer.rect)
screen_x=20;margins.right=0;layer:paintTo(bb,0,0);expect(not layer.rect,'scroll used nonexistent top page margin')
margins.right=30;layer:paintTo(bb,0,0);r=layer.rect;screen_y=-1
expect(not layer:hitTest{x=r.x+1,y=r.y+1},'scrolled-away bookmark is clickable')
screen_y=0;layer:setEnabled(false);local count=#calls;layer:paintTo(bb,0,0)
expect(#calls==count and not layer.rect and #layer.visible==0)
layer:setEnabled(true);layer:paintTo(bb,0,0);expect(layer.rect~=nil)
ui.paging=true;layer:paintTo(bb,0,0);expect(not layer.rect,'fixed-page document received EPUB indicator');ui.paging=nil
layer:resetLayout();expect(not layer.rect)
layer:setRecords({});layer:paintTo(bb,0,0);expect(not layer.rect)
expect(ui.annotation.annotations==notes and notes[1].text=='native','native annotations changed')
local big=Indicator:new{scale=function(n) return n*2 end,color=0};big.ui=ui;big.view=view
big:setRecords({first});big:paintTo(bb,0,0);expect(big.rect.w==24 and big.rect.h==36,'DPI scaling lost')
-- Repeated page paints must avoid native pointer scans without retaining stale
-- membership across navigation, layout changes, errors, or record updates.
do
    local current,total,visible,pos=1,4,1,0
    local starts={'a','b','c','d'};local scans=0;local fail=false
    local cached_doc={getPageMargins=function() return {top=30,right=30} end,getHeaderHeight=function() return 0 end,
        getCurrentPage=function() return current end,getPageCount=function() return total end,
        getVisiblePageCount=function() return visible end,getCurrentPos=function() return pos end,
        getPageXPointer=function(_,n) return starts[n] end,
        isXPointerInCurrentPage=function(_,xp) scans=scans+1;if fail then error('transient') end;return xp==current end,
        getScreenPositionFromXPointer=function() scans=scans+1;return 10,10 end}
    local cache_ui={document=cached_doc,dimen={w=600,h=800}}
    local cache_view={view_mode='page'}
    local cache_layer=Indicator:new{color=0};cache_layer.ui=cache_ui;cache_layer.view=cache_view
    local rows={};for i=1,100 do rows[i]={pos0=(i%4)+1} end
    cache_layer:setRecords(rows);cache_layer:paintTo(bb,0,0);expect(scans==100 and #cache_layer.visible==25)
    cache_layer:paintTo(bb,0,0);expect(scans==100 and #cache_layer.visible==25,'same page rescanned')
    local hit=cache_layer.rect;cache_layer:hitTest{x=hit.x+1,y=hit.y+1};expect(scans==125,'tap must recheck membership')
    current=2;cache_layer:paintTo(bb,0,0);expect(scans==225 and cache_layer.visible[1].pos0==2,'page change reused old membership')
    starts[3]='changed';cache_layer:paintTo(bb,0,0);expect(scans==325,'reflow boundary did not invalidate')
    pos=5;cache_layer:paintTo(bb,0,0);expect(scans==425,'viewport position did not invalidate')
    visible=2;cache_layer:paintTo(bb,0,0);expect(scans==525,'spread change did not invalidate')
    cache_layer:resetLayout();cache_layer:paintTo(bb,0,0);expect(scans==625,'layout reset did not invalidate')
    cache_layer:setRecords(rows);cache_layer:paintTo(bb,0,0);expect(scans==725,'record update did not invalidate')
    cache_view.view_mode='scroll';cache_layer:paintTo(bb,0,0);cache_layer:paintTo(bb,0,0)
    expect(scans==925,'scroll mode reused membership')
    cache_view.view_mode='page';cache_layer:invalidate();fail=true;cache_layer:paintTo(bb,0,0)
    fail=false;cache_layer:paintTo(bb,0,0);expect(scans==1125 and #cache_layer.visible==25,'failed scan was cached')
    cached_doc.getPageXPointer=function() return nil end
    cache_layer:paintTo(bb,0,0);cache_layer:paintTo(bb,0,0);expect(scans==1325,'missing page bounds reused membership')
    cached_doc.getPageXPointer=function(_,n) return starts[n] end
    current=4;visible=1;cache_layer:paintTo(bb,0,0);cache_layer:paintTo(bb,0,0)
    expect(scans==1425 and #cache_layer.visible==25,'last page could not be cached safely')
    cache_ui.dimen.w=620;cache_layer:paintTo(bb,0,0);expect(scans==1525,'dimension change did not invalidate')
    cached_doc.getCurrentPos=function() error('unavailable') end
    cache_layer:paintTo(bb,0,0);cache_layer:paintTo(bb,0,0);expect(scans==1725,'failed page key reused membership')
end
-- Back-and-forth navigation reuses complete page results, bounded to four
-- pages. Layout invalidation or an unidentifiable viewport clears them all.
do
    local current,scans,key_valid,failed=1,0,true,false
    local document={getPageMargins=function() return {top=30,right=30} end,getHeaderHeight=function() return 0 end,
        getCurrentPage=function() return current end,getPageCount=function() return 6 end,
        getVisiblePageCount=function() return 1 end,getCurrentPos=function() return current*100 end,
        getPageXPointer=function(_,n) return key_valid and ('page-'..n) or nil end,
        isXPointerInCurrentPage=function(_,xp) scans=scans+1;if failed then error('bad pointer') end;return xp==current end}
    local cached=Indicator:new{color=0};cached.ui={document=document,dimen={w=600,h=800}};cached.view={view_mode='page'}
    local rows={};for i=1,120 do rows[i]={pos0=(i-1)%6+1} end
    cached:setRecords(rows)
    for n=1,4 do current=n;cached:paintTo(bb,0,0);expect(#cached.visible==20) end
    expect(scans==480,'initial pages were not checked independently')
    current=2;cached:paintTo(bb,0,0);expect(scans==480 and #cached.visible==20,'returning to a recent page rescanned')
    current=5;cached:paintTo(bb,0,0);expect(scans==600 and #cached.page_cache==4,'page cache was not bounded')
    current=2;cached:paintTo(bb,0,0);expect(scans==600,'recent page was evicted instead of the oldest')
    current=1;cached:paintTo(bb,0,0);expect(scans==720,'oldest page was not evicted')
    current=2;cached:invalidate();cached:paintTo(bb,0,0);expect(scans==840,'layout invalidation retained a cached page')
    key_valid=false;cached:paintTo(bb,0,0);expect(scans==960 and not cached.page_cache,'unidentifiable viewport retained pages')
    key_valid=true;cached:paintTo(bb,0,0);expect(scans==1080,'viewport recovery reused an uncertain page')
    cached:setRecords(rows);cached:paintTo(bb,0,0);expect(scans==1200,'record update retained previous pages')
    current=3;cached:paintTo(bb,0,0);expect(scans==1320 and #cached.page_cache==2)
    current=4;failed=true;cached:paintTo(bb,0,0);expect(scans==1440 and not cached.page_cache,'failed scan retained prior pages')
    current=3;failed=false;cached:paintTo(bb,0,0);expect(scans==1560 and #cached.visible==20,'failed scan left stale membership')
end
print('bookmark_indicator_spec: '..checks..' checks passed')

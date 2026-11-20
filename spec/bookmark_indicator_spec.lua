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
expect(not layer:hitTest{x=r.x+r.w,y=r.y},'half-open right edge is active')
page=2;expect(not layer:hitTest{x=r.x+1,y=r.y+1},'stale painted page is clickable')
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
print('bookmark_indicator_spec: '..checks..' checks passed')

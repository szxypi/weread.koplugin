package.path='./?.lua;'..package.path
local Overlay=require('weread.ui.xpointer_overlay')
local Painter=require('weread.ui.personal_mark_painter')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local page,sorts=1,0
local sort=table.sort
rawset(table,'sort',function(...) sorts=sorts+1;return sort(...) end)
local document={getCurrentPos=function() return 100 end,getCurrentPage=function() return page end,
    getVisiblePageCount=function() return 1 end,getPosFromXPointer=function() return 120 end,
    getScreenBoxesFromPositions=function(_,point)
        return {{x=10+point*8,y=20,w=20,h=10}}
    end}
local records={}
for i=0,3 do records[#records+1]={pos0=i+1,pos1=i+1,style=i} end
records[#records+1]={pos0=2,pos1=2,style=1}
local overlay=Overlay:new{records=records,style={width=1,wave_step=1,color='black'},
    painter=Painter.paint,prepare_painter=Painter.prepare}
overlay.ui={document=document,dimen={h=800}};overlay.view={view_mode='page'}
local calls={}
local bb={paintRect=function(_,x,y,w,h,color) calls[#calls+1]=table.concat({'p',x,y,w,h,color},':') end,
    darkenRect=function(_,x,y,w,h,alpha) calls[#calls+1]=table.concat({'d',x,y,w,h,alpha},':') end}
local function paint() calls={};overlay:paintTo(bb,0,0);return table.concat(calls,'|') end
local first=paint()
expect(first~='' and sorts==4 and #overlay.visible==5,'initial style preparation failed')
expect(#overlay:hitTestAll{x=27,y=25}==3,'overlapping note hit targets changed')
expect(paint()==first and sorts==4,'cached repaint changed pixels or rebuilt style spans')
page=2;expect(paint()==first and sorts==8,'new page did not prepare its own styles')
page=1;expect(paint()==first and sorts==8,'returning to cached page repeated style preparation')
records[1].style=1;overlay:setRecords(records)
local edited=paint();expect(edited~=first and sorts==12,'confirmed style change kept stale geometry')
expect(paint()==edited and sorts==12,'updated style was not cached')
overlay:invalidate();expect(paint()==edited and sorts==16,'layout invalidation did not rebuild geometry')
overlay.view.view_mode='scroll';expect(paint()==edited and paint()==edited and sorts==24,'scroll reused stale page geometry')
rawset(table,'sort',sort)
do
    local current,projections=1,0
    local doc={getCurrentPage=function() return current end}
    local entry={pos0='start',pos1='end',style=0}
    local recent=Overlay:new{records={entry},style={width=1,color='black'},painter=Painter.paint,prepare_painter=Painter.prepare}
    recent.ui={document=doc,dimen={h=800}};recent.view={view_mode='page'}
    function recent:_computeVisible()
        projections=projections+1
        return {{record=entry,rect={x=current*10,y=20,w=5,h=10}}},1
    end
    local function draw() calls={};recent:paintTo(bb,0,0);return table.concat(calls,'|') end
    local frames={}
    for i=1,4 do current=i;frames[i]=draw() end
    expect(projections==4 and recent.cache_count==4,'initial page cache is not bounded')
    current=1;expect(draw()==frames[1] and projections==4,'recent page did not become most recently used')
    current=5;frames[5]=draw();expect(projections==5 and recent.cache_count==4,'fifth page exceeded cache limit')
    current=3;expect(draw()==frames[3] and projections==5,'fifth page discarded a recent page')
    current=2;expect(draw()==frames[2] and projections==6,'least recently used page was not recomputed')
    current=3;recent:invalidate();expect(recent.cache_count==0 and draw()==frames[3] and projections==7,
        'layout invalidation retained an old page')
    recent:setRecords({entry});expect(draw()==frames[3] and projections==8,'record update retained an old page')
end
print('personal_mark_overlay_cache_spec: '..checks..' checks passed')

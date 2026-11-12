package.path='./?.lua;' .. package.path
local Position=require('weread.lib.chapter_link_position')
local count=0
local function expect(value,message) count=count+1;assert(value,message) end
local function setup()
    local state={pos=587,hash=71,pages=18,height=6000,width=600,screen=800,mode='scroll',pixel_calls=0}
    local document={info={doc_height=6000},getCurrentPos=function() return state.pos end,
        getCurrentPage=function() return 2 end,getPageCount=function() return state.pages end,
        getXPointer=function() return '/body/p[18]/text().0' end,
        getDocumentRenderingHash=function() return state.hash end,
        isXPointerInDocument=function(_self,xp) return xp~='missing' end}
    local ui={document=document,view={view_mode='scroll',footer_visible=true,footer={settings={reclaim_height=false},getHeight=function() return 20 end}},
        dimen={w=600,h=800},rolling={xpointer='/body/p[18]/text().0'}}
    function ui.rolling:onGotoXPointer(xp,marker) self.xpointer=xp;state.pos=561;state.marker=marker;return true end
    function ui.rolling:_gotoPos(pos) state.pixel_calls=state.pixel_calls+1;state.pos=state.clamp and 560 or pos end
    return ui,state
end
local ui,state=setup()
local point=Position.capture(ui,'/body/link')
expect(point.xpointer==ui.rolling.xpointer and point.viewport.pos==587,'native viewport not captured')
state.pos=0
local applied,basis=Position.restore(ui,point)
expect(applied and basis=='pixel' and state.pos==587 and state.pixel_calls==1,'exact scroll offset lost')
expect(state.marker==nil,'pre-correction native marker retained wrong screen coordinate')
expect(ui.rolling.xpointer==point.xpointer,'pixel restore changed native history pointer')
for _i,change in ipairs({'hash','pages','height','width','screen','mode','footer_height','footer_visible','footer_reclaims','unknown_hash'}) do
    ui,state=setup();point=Position.capture(ui,'/body/link')
    if change=='hash' then state.hash=72
    elseif change=='pages' then state.pages=20
    elseif change=='height' then ui.document.info.doc_height=7000
    elseif change=='width' then ui.dimen.w=1264
    elseif change=='screen' then ui.dimen.h=1680
    elseif change=='mode' then ui.view.view_mode='page'
    elseif change=='footer_height' then ui.view.footer.getHeight=function() return 35 end
    elseif change=='footer_visible' then ui.view.footer_visible=false
    elseif change=='footer_reclaims' then ui.view.footer.settings.reclaim_height=true
    elseif change=='unknown_hash' then state.hash=nil end
    applied,basis=Position.restore(ui,point)
    expect(applied and basis=='anchor' and state.pos==561 and state.pixel_calls==0,'old pixel position applied after ' .. change)
    expect(state.marker=='/body/link','anchor fallback lost optional native marker')
end
for _i,value in ipairs({-1,0/0,math.huge,'587',1e16}) do
    ui,state=setup();point=Position.capture(ui);point.viewport.pos=value
    applied,basis=Position.restore(ui,point)
    expect(applied and basis=='anchor' and state.pixel_calls==0,'malformed pixel offset applied')
end
ui,state=setup();point=Position.capture(ui);point.viewport=nil
expect(Position.restore(ui,point) and state.pixel_calls==0,'legacy history point lost native fallback')
ui,state=setup();point=Position.capture(ui);state.clamp=true
applied,basis=Position.restore(ui,point)
expect(applied and basis=='anchor' and state.pos==561,'native scroll clamp left a partial pixel restore')
ui,state=setup();point=Position.capture(ui);ui.rolling._gotoPos=function() error('native failure') end
applied,basis=Position.restore(ui,point)
expect(applied and basis=='anchor' and state.pos==561,'native pixel error lost anchor fallback')
ui=setup();point=Position.capture(ui);ui.rolling.onGotoXPointer=function() error('native failure') end
expect(not Position.restore(ui,point),'failed native navigation reported success')
ui,state=setup();point=Position.capture(ui)
local navigate=ui.rolling.onGotoXPointer
ui.rolling.onGotoXPointer=function(self,xp,marker) navigate(self,xp,marker);state.hash=72 end
applied,basis=Position.restore(ui,point)
expect(applied and basis=='anchor' and state.pixel_calls==0,'native anchor reflow reused old pixel offset')
ui,state=setup();point=Position.capture(ui,'/body/link');ui.rolling._gotoPos=nil
applied,basis=Position.restore(ui,point)
expect(applied and basis=='anchor' and state.marker=='/body/link','missing native pixel method broke text navigation')
ui=setup()
for _i,value in ipairs({false,{}, {xpointer=''}, {xpointer='missing'}, {xpointer=string.rep('x',8193)}}) do
    expect(not Position.restore(ui,value),'invalid native point accepted')
end
ui,state=setup();ui.view.view_mode='page';point=Position.capture(ui)
applied,basis=Position.restore(ui,point)
expect(applied and basis=='anchor' and state.pixel_calls==0,'page mode forced pixel restoration')
print('chapter_link_position_spec: ' .. count .. ' checks passed')

package.path='./?.lua;'..package.path
local Painter=require('weread.ui.personal_mark_painter')
local Style=require('weread.lib.mark_style')
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local calls={};local bb={paintRect=function(_self,x,y,w,h,color) calls[#calls+1]={kind='stroke',x=x,y=y,w=w,h=h,color=color} end,
    darkenRect=function(_self,x,y,w,h,alpha) calls[#calls+1]={kind='shade',x=x,y=y,w=w,h=h,alpha=alpha} end}
local function box(style,x,w) return {record={style=style},rect={x=x,y=20,w=w,h=10}} end
Painter.paint(bb,{box(1,10,20),box(1,15,30),box(0,50,20),box(2,80,12)},{width=1,wave_step=1,color='black'})
expect(calls[1].kind=='shade' and calls[1].x==10 and calls[1].w==35 and calls[1].alpha==.18,'overlap darkened marker more than once')
expect(calls[2].kind=='stroke' and calls[2].x==50 and calls[2].y==29 and calls[2].w==20,'straight style changed geometry')
expect(#calls==14,'wave did not retain bounded per-column strokes')
local heights={};for i=3,#calls do heights[calls[i].y]=true;expect(calls[i].x>=80 and calls[i].x<92 and calls[i].w==1,'wave escaped its line bounds') end
expect(heights[27] and heights[28] and heights[29],'wave was drawn as a straight line')
for _i,value in ipairs({0,1,2}) do expect(Style.valid(value) and Style.labels[value],'missing supported style') end
expect(not Style.valid(3) and not Style.valid('1') and not Style.valid(.5),'invalid style accepted')
expect(Style.editable{type=1,colorStyle=5} and not Style.editable{type=0,colorStyle=0} and not Style.editable{type=1,colorStyle=6},'style editing lost color boundary')
print('personal_mark_painter_spec: '..checks..' checks')

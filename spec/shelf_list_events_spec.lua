package.path='./?.lua;'..package.path
local Router=require('weread.lib.shelf_list_events')
local rows={}
local seen
for i=1,1000 do
    local dimen={x=10,y=(i-1)*11,w=100,h=10}
    function dimen:contains(pos)
        return self.x<=pos.x and self.y<=pos.y and self.x+self.w>=pos.x+pos.w and self.y+self.h>=pos.y+pos.h
    end
    rows[i]={dimen=dimen,handleEvent=function(_,event)
        seen=i
        return event.args[1].ges~='hold_release'
    end}
end
local function event(ges,x,y,w,h)
    return {handler='onGesture',args={{ges=ges,pos={x=x,y=y,w=w or 0,h=h or 0}}}}
end
local checks=0
for _,i in ipairs({1,2,500,999,1000}) do
    for _,ges in ipairs({'tap','hold','hold_release'}) do
        for _,x in ipairs({9,10,60,110,111}) do
            for _,delta in ipairs({-0.5,0,5,10,10.5}) do
                local ev=event(ges,x,rows[i].dimen.y+delta)
                local reference
                for j,row in ipairs(rows) do if row.dimen:contains(ev.args[1].pos) then reference=j;break end end
                seen=nil
                local routed,consumed=Router.dispatch(rows,true,ev)
                assert(routed and seen==reference,'row hit differs from full propagation')
                assert((not not consumed)==(reference~=nil and ges~='hold_release'),'row consumption differs from full propagation')
                checks=checks+1
            end
        end
    end
end
for _,ges in ipairs({'touch','swipe','hold_pan','pan','pan_release'}) do
    seen=nil;local routed,consumed=Router.dispatch(rows,true,event(ges,20,20))
    assert(routed and not consumed and not seen,'scrolling gesture did not reach the parent')
end
for _,bad in ipairs({event('two_finger_swipe',20,20),event('tap',20,20,1,0),
    event('tap',20,20,0,1),event('tap',0/0,20),event('hold',20,math.huge),{handler='onClose'},
    {handler='onGesture',args={{ges='tap'}}}}) do
    seen=nil;assert(not Router.dispatch(rows,true,bad) and seen==nil,'unsupported event did not fall back')
end
assert(not Router.dispatch(rows,false,event('tap',20,20)),'unpainted list used stale geometry')
assert(not Router.dispatch(nil,true,event('tap',20,20)),'missing rows did not fall back')
print(('shelf_list_events_spec: %d hit, gap, edge and fallback checks'):format(checks))

package.path='./?.lua;'..package.path
local Paint=require('weread.lib.shelf_list_paint')
local function geometry(width,height)
    return {x=0,y=0,w=width,h=height,copy=function(self)
        return {x=self.x,y=self.y,w=self.w,h=self.h}
    end}
end
local function fixture(align,allow_mirroring)
    local group={align=align,allow_mirroring=allow_mirroring,_offsets={}}
    local widths,heights={80,90,100,90,80},{10,1,14,1,9}
    local top=0
    for i=1,#widths do
        local row=i%2==1
        local widget={_shelf_list_row=row,dimen=geometry(widths[i],heights[i]),frame={}}
        function widget:paintTo(_,x,y)
            self.count=(self.count or 0)+1;self.dimen.x,self.dimen.y=x,y
            self.frame.dimen=self.frame.dimen or self.dimen:copy()
            self.frame.dimen.x,self.frame.dimen.y=x,y
        end
        group[i]=widget;group._offsets[i]={x=widths[i],y=top};top=top+heights[i]
    end
    function group:getSize() return {w=100,h=top} end
    return group,widths,heights
end
local checks=0
for _,align in ipairs({'left','center','right'}) do
    for _,mirror in ipairs({false,true}) do
        for _,allow in ipairs({false,true}) do
            local group,widths,heights=fixture(align,allow)
            local bb={getHeight=function() return 20 end}
            for y=-40,25 do
                local old={}
                for i,widget in ipairs(group) do old[i]=widget.count or 0 end
                Paint.paint(group,bb,7,y,mirror)
                local actual_align=align
                if mirror and allow then
                    if align=='left' then actual_align='right' elseif align=='right' then actual_align='left' end
                end
                for i,widget in ipairs(group) do
                    local offset=group._offsets[i].y
                    local py=y+offset
                    local px=actual_align=='center' and 7+math.floor((100-widths[i])/2)
                        or actual_align=='right' and 7+100-widths[i] or 7
                    local visible=py<20 and py+heights[i]>0
                    assert((widget.count or 0)==old[i]+(visible and 1 or 0),'wrong visibility or clipping boundary')
                    if visible or widget._shelf_list_row then
                        assert(widget.dimen.x==px and widget.dimen.y==py,'gesture geometry was stale')
                        assert(widget.frame.dimen.x==px and widget.frame.dimen.y==py,'focus geometry was stale')
                    end
                    checks=checks+1
                end
            end
        end
    end
end
do
    local row={_shelf_list_row=true,dimen=geometry(80,10),calls=0}
    function row:setOffscreenGeometry(x,y) self.calls=self.calls+1;self.dimen.x,self.dimen.y=x,y end
    function row:paintTo() error('offscreen row was painted') end
    local group={row,align='left',allow_mirroring=true,_offsets={{x=80,y=0}}}
    function group:getSize() return {w=80,h=10} end
    Paint.paint(group,{getHeight=function() return 20 end},7,-20,false)
    assert(row.calls==1 and row.dimen.x==7 and row.dimen.y==-20,'lazy row did not receive its offscreen position')
end
print(('shelf_list_paint_spec: %d visibility, alignment, and geometry checks'):format(checks))

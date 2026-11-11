-- Monochrome personal styles: preserve text while shading markers, and keep
-- straight/wavy strokes distinct. Coalesce overlaps before shading once.
local M={}
local function spans(boxes,kind)
    local rows={}
    for _i,entry in ipairs(boxes) do
        local style=entry.record.style or 0
        if (kind==1 and style==1) or (kind==2 and style==2) or (kind==0 and style~=1 and style~=2) then
            local r=entry.rect;rows[#rows+1]={x=r.x,right=r.x+r.w,y=r.y,h=r.h}
        end
    end
    table.sort(rows,function(a,b)
        return a.y==b.y and (a.h==b.h and a.x<b.x or a.h<b.h) or a.y<b.y
    end)
    local merged={}
    for _i,row in ipairs(rows) do
        local last=merged[#merged]
        if last and last.y==row.y and last.h==row.h and row.x<=last.right then last.right=math.max(last.right,row.right)
        else merged[#merged+1]=row end
    end
    return merged
end
function M.paint(bb,boxes,style)
    for _i,r in ipairs(spans(boxes,1)) do bb:darkenRect(r.x,r.y,r.right-r.x,r.h,.18) end
    for _i,r in ipairs(spans(boxes,0)) do bb:paintRect(r.x,r.y+r.h-1,r.right-r.x,style.width,style.color) end
    local step=style.wave_step or style.width
    for _i,r in ipairs(spans(boxes,2)) do
        local index=0
        for x=r.x,r.right-1,step do
            local phase=index%4;local rise=phase==3 and 1 or phase
            bb:paintRect(x,r.y+r.h-1-(2-rise)*step,math.min(step,r.right-x),style.width,style.color)
            index=index+1
        end
    end
end
return M

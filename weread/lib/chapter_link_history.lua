-- Private, in-memory boundaries between native ReaderLink history stacks.
local M={MAX_FRAMES=64,MAX_STACK=256}
local boundary={}
local function copy_location(value)
    local out={}
    for key,item in pairs(value) do if key~=boundary then out[key]=item end end
    return out
end
function M.marker(location,frame)
    local out=copy_location(location);out[boundary]=frame;return out
end
function M.candidate(link,direction)
    local stack=direction=='back' and link.location_stack or link.forward_location_stack
    local index=#stack
    local value=stack[index]
    if value and not value[boundary] and link:compareLocationToCurrent(value) then
        index=index-1;value=stack[index]
    end
    return value and value[boundary],index
end
function M.stacks(link,direction,index)
    local memo,count={},0
    local clone_stack,clone_frame
    clone_frame=function(frame)
        if memo[frame] then return memo[frame] end
        if count>=M.MAX_FRAMES then return nil end
        count=count+1
        local out={};memo[frame]=out
        for key,value in pairs(frame) do
            if key~='back' and key~='forward' then out[key]=value end
        end
        out.back=clone_stack(frame.back);out.forward=clone_stack(frame.forward)
        return out
    end
    clone_stack=function(stack,last)
        local out={};last=last or #stack
        for n=math.max(1,last-M.MAX_STACK+1),last do
            local value=stack[n]
            local frame=value[boundary] and clone_frame(value[boundary])
            if not value[boundary] or frame then
                local item=copy_location(value);item[boundary]=frame;out[#out+1]=item
            end
        end
        return out
    end
    return clone_stack(link.location_stack,direction=='back' and index-1 or nil),
        direction=='new' and {} or clone_stack(link.forward_location_stack,direction=='forward' and index-1 or nil)
end
function M.restore(link,frame,direction,departing,location)
    local fake={location_stack=frame and frame.back or {},forward_location_stack=frame and frame.forward or {}}
    link.location_stack,link.forward_location_stack=M.stacks(fake)
    local stack=direction=='back' and link.forward_location_stack or link.location_stack
    stack[#stack+1]=M.marker(location,departing)
end
return M

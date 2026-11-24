package.path='./?.lua;'..package.path
local Visible=require('weread.lib.shelf_visible')
local checks=0

local function check(heights,top,height)
    local source,bottoms={},{}
    local y=0
    for i,h in ipairs(heights) do
        source[i]={id=i}
        bottoms[i]=y+h
        y=bottoms[i]+1
    end
    local expected={};y=0
    for i,h in ipairs(heights) do
        local bottom=y+h
        if bottom>top and y<top+height then expected[#expected+1]=source[i] end
        if y>=top+height then break end
        y=bottom+1
    end
    local actual=Visible.books(source,bottoms,top,height)
    assert(#actual==#expected,('wrong count for top=%s height=%s'):format(top,height))
    for i,item in ipairs(expected) do assert(actual[i]==item,'wrong book or order') end
    checks=checks+1
end

for _,heights in ipairs({{}, {0}, {7}, {4,0,7,3}, {1,1,1,1,1}}) do
    for top=-3,35,.5 do for _,height in ipairs({0,1,2,6,50}) do check(heights,top,height) end end
end
local heights={};for i=1,1500 do heights[i]=(i*37)%101 end
for i=1,400 do
    check(heights,(i*7919)%80000-50,({0,1,300,900,1700})[(i%5)+1])
end
print(('shelf_visible_spec: %d viewport and boundary checks'):format(checks))

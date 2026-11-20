-- Independent cloud bookmark corner. Receives only source/DOM-verified points;
-- never sets ReaderDogear state, native annotations or a reading position.
local M={};M.__index=M
function M:new(options)
    options=options or {}
    return setmetatable({records={},enabled=true,visible={},scale=options.scale or function(n) return n end,
        color=options.color},self)
end
function M:setRecords(records) self.records=records or {};self:invalidate() end
function M:setEnabled(value) self.enabled=value~=false;self:invalidate() end
function M:invalidate() self.visible={};self.rect=nil;self.origin=nil end
function M:resetLayout() self:invalidate() end
local function onscreen(self,document,xp)
    if self.view.view_mode=='page' then
        return type(document.isXPointerInCurrentPage)=='function' and document:isXPointerInCurrentPage(xp)==true
    end
    if self.view.view_mode~='scroll' or type(document.getScreenPositionFromXPointer)~='function' then return false end
    local y,x=document:getScreenPositionFromXPointer(xp);local dimen=self.ui.dimen
    local footer=self.view.footer_visible and self.view.footer and self.view.footer:getHeight() or 0
    return type(y)=='number' and type(x)=='number' and y>=0 and y<dimen.h-footer and x>=0 and x<dimen.w
end
function M:geometry()
    local ui,view=self.ui,self.view;local d=ui and ui.document;local dimen=ui and ui.dimen
    if not d or not dimen or not view or type(d.getPageMargins)~='function' then return end
    local margins=d:getPageMargins();if type(margins)~='table' then return end
    local minimum=math.max(6,self.scale(8))
    local w,h,p=math.max(minimum,self.scale(12)),math.max(12,self.scale(18)),math.max(1,self.scale(2))
    local header=view.view_mode=='page' and d:getHeaderHeight() or 0
    local y=header+p
    local dogear=view.dogear_visible and view.dogear and view.dogear.dogear_size or 0
    -- Stay in an actual page margin and leave the native dogear intact.
    if tonumber(margins.right) and margins.right>=minimum+p then
        w=math.min(w,margins.right-p);h=math.ceil(w*1.5)
        if dogear>0 then y=header+dogear+p end
    elseif view.view_mode=='page' and tonumber(margins.top) and margins.top>=math.ceil(minimum*1.5)+p then
        h=math.min(h,margins.top-p);w=math.floor(h/1.5)
    else return end
    local x=dimen.w-w-p
    if dogear>0 and (tonumber(margins.right) or 0)<minimum+p then x=x-dogear-p end
    if x<0 or y<0 or x+w>dimen.w or y+h>dimen.h then return end
    return {x=x,y=y,w=w,h=h}
end
function M:paintTo(bb,x,y)
    self:invalidate()
    if not self.enabled or not self.ui or self.ui.paging or not self.view then return end
    local document=self.ui.document;if not document or not self.ui.dimen then return end
    for _i,row in ipairs(self.records) do
        local ok,visible=pcall(onscreen,self,document,row.pos0)
        if ok and visible then self.visible[#self.visible+1]=row end
    end
    if #self.visible==0 then return end
    local ok,r=pcall(self.geometry,self);if not ok or not r then self.visible={};return end
    local left,top=r.x+(x or 0),r.y+(y or 0);local line=math.max(1,self.scale(1))
    self.origin={x=x or 0,y=y or 0};self.rect={x=left,y=top,w=r.w,h=r.h}
    local color=self.color or require('ffi/blitbuffer').COLOR_BLACK
    -- An outline ribbon stays distinct from KOReader's triangular dogear.
    bb:paintRect(left,top,r.w,line,color)
    bb:paintRect(left,top,line,r.h,color);bb:paintRect(left+r.w-line,top,line,r.h,color)
    local half=math.floor(r.w/2);local depth=math.floor(r.w/3)
    for at=line,r.w-line-1 do
        local rise=math.floor((half-math.abs(at-half))*depth/math.max(1,half))
        bb:paintRect(left+at,top+r.h-line-rise,1,line,color)
    end
end
function M:hitTest(pos)
    local r=self.rect
    if not self.enabled or not r or not pos or type(pos.x)~='number' or type(pos.y)~='number' then return end
    local ok,geometry=pcall(self.geometry,self)
    if not ok or not geometry or geometry.x+self.origin.x~=r.x or geometry.y+self.origin.y~=r.y
        or geometry.w~=r.w or geometry.h~=r.h then return end
    if pos.x>=r.x and pos.x<r.x+r.w and pos.y>=r.y and pos.y<r.y+r.h then
        for _i,row in ipairs(self.visible) do
            local valid,show=pcall(onscreen,self,self.ui.document,row.pos0)
            if valid and show then return row end
        end
    end
end
return M

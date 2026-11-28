-- Independent cloud bookmark corner. Receives only source/DOM-verified points;
-- never sets ReaderDogear state, native annotations or a reading position.
local M={};M.__index=M
local PAGE_CACHE_LIMIT=4
function M:new(options)
    options=options or {}
    return setmetatable({records={},enabled=true,visible={},scale=options.scale or function(n) return n end,
        color=options.color,allow_page_index=options.allow_page_index~=false},self)
end
function M:setRecords(records) self.records=records or {};self:invalidate() end
function M:setEnabled(value) self.enabled=value~=false;self:invalidate() end
local function clear_visible(self) self.visible={};self.rect=nil;self.origin=nil end
function M:invalidate() clear_visible(self);self.page_cache=nil;self.page_index=nil end
function M:resetLayout() self:invalidate() end
-- Only reuse a result when the native renderer can identify the entire
-- viewport. Scroll mode and incomplete/failed document APIs always rescan.
local function page_key(self,document)
    if self.view.view_mode~='page' or #self.records<8 then return end
    if type(self.ui.dimen.w)~='number' or type(self.ui.dimen.h)~='number' then return end
    local names={'getCurrentPage','getPageCount','getVisiblePageCount','getCurrentPos','getPageXPointer'}
    for _,name in ipairs(names) do if type(document[name])~='function' then return end end
    local page,total,count,pos=document:getCurrentPage(),document:getPageCount(),document:getVisiblePageCount(),document:getCurrentPos()
    if type(page)~='number' or page%1~=0 or type(total)~='number' or total%1~=0
        or type(count)~='number' or count%1~=0 or type(pos)~='number'
        or page<1 or total<page or count<1 then return end
    local first=document:getPageXPointer(page)
    if type(first)~='string' or first=='' then return end
    local last=false
    if page+count<=total then
        last=document:getPageXPointer(page+count)
        if type(last)~='string' or last=='' then return end
    end
    local hash=false
    if type(document.getDocumentRenderingHash)=='function' then
        local ok,value=pcall(document.getDocumentRenderingHash,document,true)
        if ok and (type(value)=='number' and value==value and value~=0 and math.abs(value)<math.huge
            or type(value)=='string' and value~='') then hash=value end
    end
    local flows='unknown'
    if type(document.hasNonLinearFlows)=='function' then
        local ok,value=pcall(document.hasNonLinearFlows,document)
        if ok and type(value)=='boolean' then flows=value and 'nonlinear' or 'linear' end
    end
    return {document,page,total,count,pos,first,last,self.ui.dimen.w,self.ui.dimen.h,hash,flows}
end
local function same_key(a,b)
    if not a or not b then return false end
    for i=1,#a do if a[i]~=b[i] then return false end end
    return true
end
local function cached_page(self,key)
    if not key or not self.page_cache then return end
    for i,entry in ipairs(self.page_cache) do
        if same_key(key,entry.key) then
            if i>1 then table.remove(self.page_cache,i);table.insert(self.page_cache,1,entry) end
            return entry
        end
    end
end
local function onscreen(self,document,xp)
    if self.view.view_mode=='page' then
        return type(document.isXPointerInCurrentPage)=='function' and document:isXPointerInCurrentPage(xp)==true
    end
    if self.view.view_mode~='scroll' or type(document.getScreenPositionFromXPointer)~='function' then return false end
    local y,x=document:getScreenPositionFromXPointer(xp);local dimen=self.ui.dimen
    local footer=self.view.footer_visible and self.view.footer and self.view.footer:getHeight() or 0
    return type(y)=='number' and type(x)=='number' and y>=0 and y<dimen.h-footer and x>=0 and x<dimen.w
end

-- A page-number index is only a prefilter: visible candidates are still
-- checked by CREngine. Unsupported/multi-page/non-linear layouts and any
-- uncertain page mappings retain the original complete scan.
local function page_candidates(self,document,key)
    if not self.allow_page_index or not key or not key[10] or key[11]~='linear' or key[4]~=1 or #self.records<32
        or type(document.getPageFromXPointer)~='function' then
        self.page_index=nil;return nil
    end
    -- Check the page anchor each time before using this provider's numbering.
    local valid,first=pcall(document.getPageFromXPointer,document,key[6])
    if not valid or type(first)~='number' or first%1~=0 or math.abs(first-key[2])>1 then
        self.page_index=nil;self.page_cache=nil;return nil
    end
    local layout={document,key[3],key[4],key[8],key[9],key[10]}
    local index=self.page_index
    if not index or not same_key(index.layout,layout) then
        index={layout=layout,buckets={},unknown={}}
        local pages={}
        for i,row in ipairs(self.records) do
            local xp=row.pos0
            local page=type(xp)=='string' and pages[xp] or nil
            if page==nil then
                local success,value=pcall(document.getPageFromXPointer,document,xp)
                if success and type(value)=='number' and value%1==0 and value>=1 and value<=key[3] then
                    page=value
                    if type(xp)=='string' then pages[xp]=page end
                end
            end
            local bucket
            if page then
                bucket=index.buckets[page] or {};index.buckets[page]=bucket
            else bucket=index.unknown end
            bucket[#bucket+1]=i
        end
        self.page_index=index
    end
    local included={}
    local function add(rows) for _,i in ipairs(rows or {}) do included[i]=true end end
    add(index.unknown)
    for page=key[2]-1,key[2]+1 do add(index.buckets[page]) end
    return included
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
    clear_visible(self)
    if not self.enabled or not self.ui or self.ui.paging or not self.view then return end
    local document=self.ui.document;if not document or not self.ui.dimen then return end
    local key_ok,key=pcall(page_key,self,document)
    local cached=key_ok and cached_page(self,key)
    if cached then
        self.visible=cached.visible
    else
        local complete=true
        local candidates=key_ok and page_candidates(self,document,key)
        for i,row in ipairs(self.records) do
            if not candidates or candidates[i] then
                local ok,visible=pcall(onscreen,self,document,row.pos0)
                if not ok then complete=false elseif visible then self.visible[#self.visible+1]=row end
            end
        end
        if key_ok and key and complete then
            self.page_cache=self.page_cache or {}
            table.insert(self.page_cache,1,{key=key,visible=self.visible})
            if #self.page_cache>PAGE_CACHE_LIMIT then table.remove(self.page_cache) end
        else
            -- An incomplete viewport or failed query may indicate a changed
            -- layout, so no prior page can safely be reused.
            self.page_cache=nil;self.page_index=nil
        end
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
function M:hitTestAll(pos)
    local records,seen={},{}
    local r=self.rect
    if not self.enabled or not r or not pos or type(pos.x)~='number' or type(pos.y)~='number' then return records end
    local ok,geometry=pcall(self.geometry,self)
    if not ok or not geometry or geometry.x+self.origin.x~=r.x or geometry.y+self.origin.y~=r.y
        or geometry.w~=r.w or geometry.h~=r.h then return records end
    if pos.x>=r.x and pos.x<r.x+r.w and pos.y>=r.y and pos.y<r.y+r.h then
        for _i,row in ipairs(self.visible) do
            local valid,show=pcall(onscreen,self,self.ui.document,row.pos0)
            if valid and show and not seen[row] then records[#records+1]=row;seen[row]=true end
        end
    end
    return records
end
function M:hitTest(pos)
    return self:hitTestAll(pos)[1]
end
return M

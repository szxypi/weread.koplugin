-- Scoped emoji fallback for native thought text. Keep the reader's primary
-- face, metrics and fallback order; never change KOReader's shared font list.
local M={}
local faces=setmetatable({},{__mode='kv'})
local Viewer, ThoughtMenu, TextWidget

function M.face(base)
    if not base or not base.getFallbackFont or not base.ftsize then return base end
    if faces[base] then return faces[base] end
    local factory=require('weread.ui.thought_popup.face_factory')
    local emoji=factory:_getFallbackFace(factory:findEmojiFont(),base.size)
    if not emoji then return base end
    local face={}
    for key,value in pairs(base) do face[key]=value end
    face.fallbacks={}
    face.embolden_half_strength=face.embolden_half_strength or base.ftsize:getEmboldenHalfStrength(3/8)
    -- xtext has 16 face slots including the primary face. Emoji must be last:
    -- a later fallback can otherwise replace a partially supported cluster.
    local ended=false
    face.getFallbackFont=function(num)
        if num==nil or num==0 then return face end
        if type(num)~='number' or num%1~=0 or num<1 or num>15 then return false end
        for index=1,num do
            if face.fallbacks[index]==nil then
                if ended then face.fallbacks[index]=false
                else
                    local fallback=base.getFallbackFont(index)
                    face.fallbacks[index]=fallback or emoji
                    if not fallback then ended=true end
                end
            end
        end
        return face.fallbacks[num]
    end
    faces[base],faces[face]=face,face
    return face
end

function M.input(options)
    options.input_face=M.face(options.input_face or require('ui/font'):getFace('x_smallinfofont'))
    return require('ui/widget/inputdialog'):new(options)
end

function M.viewer(options)
    if not Viewer then
        local Parent=require('ui/widget/textviewer')
        Viewer=Parent:extend{}
        function Viewer:init(...)
            Parent.init(self,...)
            local box=self.is_txt and self.box_widget
            if not box or not box.use_xtext then return end
            local face=M.face(box.face)
            if face==box.face then return end
            -- TextViewer has no face option. Rebuild just its text box, after
            -- freeing the old shaper, on initial layout and font-size changes.
            box:free()
            box.face,box.charlist=face,nil
            self.scroll_widget.face=face
            box:init()
            self.scroll_widget:resetScroll()
        end
    end
    return Viewer:new(options)
end


-- KOReader Menu has no per-menu face option. Patch only the widgets in this
-- menu after its normal page layout, leaving shared fonts and other menus
-- untouched. If an older KOReader has a different row layout, keep its
-- native rendering rather than guessing at the widget tree.
local function missing(widget)
    if not widget or not widget.use_xtext then return false end
    if widget.updateSize then widget:updateSize() end
    if not widget._xtext then return false end
    if widget.vertical_string_list and widget._shapeLine then
        for _,line in ipairs(widget.vertical_string_list) do
            widget:_shapeLine(line)
            for _,glyph in ipairs(line.xglyphs or {}) do
                if glyph.glyph==0 and not glyph.no_drawing then return true end
            end
        end
    elseif widget._shape_start and widget._shape_end then
        local native=widget.paintTo==TextWidget.paintTo and widget._measureWithXText
            and widget._measureWithXText==TextWidget._measureWithXText
        local shaped=native and widget._xshaping
        if not shaped then
            shaped=widget._xtext:shapeLine(widget._shape_start,widget._shape_end,widget._shape_idx_to_substitute_with_ellipsis)
            -- Native TextWidget paints this same span and clears its cache when remeasured.
            if native then widget._xshaping=shaped end
        end
        for _,glyph in ipairs(shaped or {}) do if glyph.glyph==0 and not glyph.no_drawing then return true end end
    end
    return false
end
local function row_widgets(row)
    local underline=row and row._underline_container
    local overlap=underline and underline[1] and underline[1][1]
    local left=overlap and overlap[2]
    local right=overlap and overlap[3]
    local group=left and left[1]
    local span=group and group[1]
    local text=group and group[2]
    local mandatory=right and right[1]
    if not (type(row.content_width)=='number' and row.content_width>=2 and type(span)=='table' and type(span.width)=='number'
        and type(group.resetLayout)=='function' and type(text)=='table' and type(text.text)=='string'
        and type(mandatory)=='table' and type(mandatory.getWidth)=='function'
        and type(row.text)=='string' and text.text==row.text:gsub('\n',' ')
        and not row.post_text and not row.with_dots and not row.text_bgcolor) then return end
    return text,mandatory,group,span.width
end
local function rebuild(widget,face,width)
    local textbox=widget.vertical_string_list and widget.init
    if type(widget.free)~='function' or not textbox and type(widget.updateSize)~='function' then return false end
    widget:free();widget.face=face
    if textbox then
        widget.width=width
        widget.charlist=nil;widget:init()
    else
        widget.max_width=width
        widget:updateSize()
    end
    return true
end
local function safe_rebuild(widget,face,width)
    local previous_face=widget.face
    local previous_width=widget.vertical_string_list and widget.width or widget.max_width
    local ok,changed=pcall(rebuild,widget,face,width)
    if ok and changed then return true end
    -- A different KOReader version or an unavailable face must not leave the
    -- original widget with a freed shaper or a partially applied font.
    pcall(rebuild,widget,previous_face,previous_width)
    return false
end
local function patch_row(row)
    local text,mandatory,group,state_width=row_widgets(row)
    if not text or not text.use_xtext then return false end
    local text_face=missing(text) and M.face(text.face) or text.face
    local mandatory_face=missing(mandatory) and M.face(mandatory.face) or mandatory.face
    local fix_text=text_face~=text.face
    local fix_mandatory=mandatory_face~=mandatory.face
    if not fix_text and not fix_mandatory then return false end
    if fix_mandatory then fix_mandatory=safe_rebuild(mandatory,mandatory_face,math.floor(row.content_width/2)) end
    local gap=(row.mandatory or row.mandatory_func) and require('ui/size').span.horizontal_default or 0
    local available=math.max(1,row.content_width-state_width-mandatory:getWidth()-gap)
    local updated=(fix_text or fix_mandatory) and safe_rebuild(text,text_face,available)
    if not updated and fix_mandatory then updated=safe_rebuild(text,text.face,available) end
    if updated or fix_mandatory then group:resetLayout();return true end
    return false
end
function M.menu(options)
    local Parent=require('ui/widget/menu')
    if not Parent.extend then return Parent:new(options) end
    if not ThoughtMenu then
        TextWidget=require('ui/widget/textwidget')
        ThoughtMenu=Parent:extend{}
        function ThoughtMenu:updateItems(...)
            Parent.updateItems(self,...)
            local changed=false
            for _,row in ipairs(self.item_group or {}) do
                local ok,patched=pcall(patch_row,row)
                if ok and patched then changed=true end
            end
            if changed and self.item_group.resetLayout then self.item_group:resetLayout() end
        end
    end
    return ThoughtMenu:new(options)
end

return M

-- Scoped emoji fallback for native thought text. Keep the reader's primary
-- face, metrics and fallback order; never change KOReader's shared font list.
local M={}
local faces=setmetatable({},{__mode='kv'})
local Viewer

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

return M

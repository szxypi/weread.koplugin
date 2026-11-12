-- Real xtext/FreeType glyph assertions. All strings are synthetic.
local M={}
function M.glyphs(box,text)
    assert(box.use_xtext and box._xtext,'native text shaper missing')
    local result={}
    for _i,line in ipairs(box.vertical_string_list) do
        box:_shapeLine(line)
        for _j,glyph in ipairs(line.xglyphs or {}) do
            if not glyph.no_drawing then
                result[#result+1]={glyph=glyph.glyph,index=glyph.text_index,font=box.face.getFallbackFont(glyph.font_num),
                    advance=glyph.w,x0=glyph.x0,y_offset=glyph.y_offset}
            end
        end
    end
    if text then assert(box.text==text,'native display text changed') end
    return result
end
function M.emoji(box,chars)
    local found=0
    local chars_list=require("util").splitToChars(box.text or "")
    for _i,glyph in ipairs(M.glyphs(box)) do
        local char=chars_list[glyph.index]
        if chars[char] then
            assert(glyph.glyph>0 and glyph.font.realname:match('NotoEmoji%-Regular%.ttf$'),'emoji rendered as missing glyph')
            local raster=require('ui/rendertext'):getGlyphByIndex(glyph.font,glyph.glyph,false)
            local bitmap=raster.bb
            assert(bitmap:getWidth()>0 and bitmap:getHeight()>0,'emoji has no raster')
            local top=box.line_glyph_baseline-raster.t-glyph.y_offset
            assert(top>=0 and top+bitmap:getHeight()<=box.line_height_px+box.line_glyph_extra_height,'emoji clipped by line bounds')
            found=found+1
        end
    end
    assert(found>0,'emoji assertion found no selected glyph')
    return found
end
function M.input(dialog,chars)
    local input=assert(dialog._input_widget)
    return M.emoji(input.scroll and input.text_widget.text_widget or input.text_widget,chars)
end
function M.run()
    local Text=require('weread.ui.thought_text')
    local Font=require('ui/font');local Box=require('ui/widget/textboxwidget');local Device=require('device')
    local original_get,original_fallbacks=Font.getFace,table.concat(Font.fallbacks,'|')
    local base=Font:getFace('x_smallinfofont',20);local original_callback=base.getFallbackFont
    local scoped=Text.face(base)
    assert(scoped~=base and scoped.ftsize==base.ftsize and scoped.size==base.size)
    local width=Device.screen:getWidth()-Device.screen:scaleBySize(60)
    local function box(face,text) return Box:new{face=face,text=text,width=width} end
    local missing=box(base,'😀');local fixed=box(scoped,'😀')
    assert(M.glyphs(missing)[1].glyph==0,'baseline no longer reproduces missing glyph')
    assert(M.emoji(fixed,{['😀']=true})==1)
    missing:free();fixed:free()
    local plain='中文 Latin 123 & 标点，。\n第二行 café'
    local a,b=box(base,plain),box(scoped,plain)
    local ga,gb=M.glyphs(a,plain),M.glyphs(b,plain)
    assert(#ga==#gb and a:getAllLineCount()==b:getAllLineCount() and a:getTextHeight()==b:getTextHeight())
    for index,glyph in ipairs(ga) do
        local other=gb[index]
        assert(glyph.font.hash==other.font.hash and glyph.glyph==other.glyph and glyph.index==other.index
            and glyph.advance==other.advance and glyph.x0==other.x0,'ordinary text metrics or glyph changed')
    end
    a:free();b:free()
    local mixed=box(scoped,'中文 😀🙂👍🏽❤️👩‍💻👨‍👩‍👧‍👦1️⃣🇨🇳 café\n第二行。')
    for _i,glyph in ipairs(M.glyphs(mixed)) do assert(glyph.glyph>0,'mixed emoji sequence has missing glyph') end
    mixed:free()
    local viewer=Text.viewer{text='中文 😀🙂\n第二行',buttons_table={{{id='synthetic',text='OK'}}},add_default_buttons=true}
    assert(M.emoji(viewer.box_widget,{['😀']=true,['🙂']=true})==2)
    local buttons=#viewer.buttons_table
    viewer.text_font_size=30;viewer:reinit()
    assert(M.emoji(viewer.box_widget,{['😀']=true,['🙂']=true})==2 and #viewer.buttons_table==buttons)
    assert(viewer.box_widget.face.size==Device.screen:scaleBySize(30),'font resize was scaled twice')
    viewer.monospace_font=true;viewer:reinit()
    assert(M.emoji(viewer.box_widget,{['😀']=true,['🙂']=true})==2)
    viewer.box_widget:free()
    -- reinit normally persists the user's explicit local viewer preference.
    -- Restore this synthetic profile's default before testing actual UI flows.
    G_reader_settings:delSetting('textviewer_text_types')
    assert(Font.getFace==original_get and table.concat(Font.fallbacks,'|')==original_fallbacks
        and base.getFallbackFont==original_callback and Font:getFace('x_smallinfofont',20)==base,'shared font API changed')
    return {result='PASS',baseline_missing_glyph_reproduced=true,emoji_rasterized=true,ordinary_text_metrics_equal=true,
        mixed_emoji_sequences=true,resize_and_monospace=true,global_font_api_unchanged=true}
end
return M

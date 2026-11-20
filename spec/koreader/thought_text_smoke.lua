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
-- Inspect the actual MenuItem text widget, not the source row, after layout.
function M.menu_text(menu,needle)
    local seen={}
    local function find(node)
        if type(node)~='table' or seen[node] then return nil end
        seen[node]=true
        if type(node.text)=='string' and node.text:find(needle,1,true) and node.face and node.updateSize then
            node:updateSize()
            if node._xtext and node._shape_start and node._shape_end then return node end
        end
        for _,child in ipairs(node) do local hit=find(child);if hit then return hit end end
    end
    for _,row in ipairs(menu.item_group or {}) do local hit=find(row);if hit then return hit,row end end
end
function M.menu_box(menu,needle)
    local seen={}
    local function find(node)
        if type(node)~='table' or seen[node] then return nil end
        seen[node]=true
        if type(node.text)=='string' and node.text:find(needle,1,true) and node.vertical_string_list
            and node._xtext and node.face then return node end
        for _,child in ipairs(node) do local hit=find(child);if hit then return hit end end
    end
    for _,row in ipairs(menu.item_group or {}) do local hit=find(row);if hit then return hit,row end end
end
function M.menu_emoji(menu,char)
    local widget,row=M.menu_text(menu,char);assert(widget and row,'menu text widget missing')
    local chars=require('util').splitToChars(widget.text)
    local glyphs=widget._xtext:shapeLine(widget._shape_start,widget._shape_end,widget._shape_idx_to_substitute_with_ellipsis)
    local count=0
    for _,glyph in ipairs(glyphs) do
        if chars[glyph.text_index]==char and not glyph.no_drawing then
            local face=widget.face.getFallbackFont(glyph.font_num)
            assert(glyph.glyph>0 and face.realname:match('NotoEmoji%-Regular%.ttf$'),'menu emoji has no fallback glyph')
            local raster=require('ui/rendertext'):getGlyphByIndex(face,glyph.glyph,false)
            assert(raster.bb:getWidth()>0 and raster.bb:getHeight()>0,'menu emoji has no bitmap')
            count=count+1
        end
    end
    assert(count>0,'menu emoji not visible');return widget,row
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
    local Menu=require('ui/widget/menu');local UI=require('ui/uimanager')
    local rows={{text='Plain 中文 123',mandatory='书名'}, {text='Emoji 😀 end',mandatory='书名'}}
    local baseline=Menu:new{title='Synthetic',item_table=rows,is_popout=true,items_per_page=1,items_font_size=22,single_line=true,is_enable_shortcut=false}
    local scoped_menu=Text.menu{title='Synthetic',item_table=rows,is_popout=true,items_per_page=1,items_font_size=22,single_line=true,is_enable_shortcut=false}
    local ordinary=M.menu_text(baseline,'Plain 中文 123');local scoped_ordinary=M.menu_text(scoped_menu,'Plain 中文 123')
    assert(ordinary and scoped_ordinary and ordinary:getWidth()==scoped_ordinary:getWidth()
        and ordinary.face==scoped_ordinary.face,'ordinary menu text metrics or font changed')
    scoped_menu:onNextPage();local main=M.menu_emoji(scoped_menu,'😀')
    assert(main:getWidth()<=main.max_width,'scoped text exceeded row width')
    scoped_menu:onPrevPage();assert(M.menu_text(scoped_menu,'Plain 中文 123'),'previous page lost its row')
    scoped_menu:onNextPage();M.menu_emoji(scoped_menu,'😀')
    UI:close(baseline);UI:close(scoped_menu)
    local long=Text.menu{title='Synthetic',item_table={{text='😀 '..string.rep('中文',150),mandatory='书名'}},
        is_popout=true,items_per_page=8,items_font_size=22,single_line=true,is_enable_shortcut=false}
    UI:show(long);UI:forceRePaint()
    local long_text,long_row=M.menu_emoji(long,'😀')
    local overlap=long_row._underline_container[1][1];local left,right=overlap[2],overlap[3]
    assert(long_text:isTruncated() and left.dimen.x+left[1][1].width+long_text:getWidth()<=right.dimen.x+1,
        'long emoji preview overlapped its book title')
    UI:close(long)
    local label=Text.menu{title='Synthetic',item_table={{text=string.rep('正文',50),mandatory='书名 😀'}},
        is_popout=true,items_per_page=8,items_font_size=22,single_line=true,is_enable_shortcut=false}
    UI:show(label);UI:forceRePaint();M.menu_emoji(label,'😀');UI:close(label)
    local multiline=Text.menu{title='Synthetic',item_table={{text='中文 😀 '..string.rep('文字',30),mandatory='书名'}},
        is_popout=true,items_per_page=8,items_font_size=22,single_line=false,multilines_forced=true,is_enable_shortcut=false}
    local multi=M.menu_box(multiline,'😀');assert(multi and M.emoji(multi,{['😀']=true})==1,'multiline menu fallback missing')
    UI:show(multiline);UI:forceRePaint();UI:close(multiline)
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

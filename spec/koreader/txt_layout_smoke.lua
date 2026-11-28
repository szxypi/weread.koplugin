-- Isolated synthetic text, rendered by KOReader's real CRE engine.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Content=require('weread.lib.content')
local settings=require('weread.lib.settings'):new()
assert(settings.mock_endpoint and settings.data_dir:match('/weread%-mock$'))
local raw='STARTLINE Alpha marker.\n    INDENTLINE Four spaces before this text.  \n\n'
    ..'AFTERBLANK The next paragraph should follow an empty line.\n'
    ..'LONGLINE '..string.rep('This sentence must wrap on the screen. ',8)..'WRAPPEDEND\nTAILLINE Final marker.'
local chapters={{chapterUid=1,chapterIdx=1,title='Synthetic',wordCount=1000}}
local book={book_id='900001',title='Synthetic TXT layout',author='Synthetic',chapters=chapters}
local rendered=Content.txt_to_xhtml(raw)
local path=Content.save_book_epub(settings,book,chapters,{['1']=rendered},'txt-layout')
local document=assert(require('document/documentregistry'):openDocument(path))
assert(document:loadDocument());document:setFontFace('Noto Sans CJK SC');document:setupFallbackFontFaces()
document:setFontSize(Device.screen:scaleBySize(22));document:render();document:gotoPage(1)
local body='/body/DocFragment[1]/body/'
local function position(paragraph)
    local xp=assert(document:getNextVisibleChar(body..'p['..paragraph..'].0'))
    local y,x=document:getPosFromXPointer(xp)
    assert(type(x)=='number' and type(y)=='number')
    return x,y,xp
end
local x1,y1=position(1);local x2,y2=position(2);local y4=select(2,position(4))
local indent_xp=body..'p[2]/text().4'
local indent_x=select(2,document:getPosFromXPointer(indent_xp))
local first_indent_char=document:getTextFromXPointers(indent_xp,body..'p[2]/text().5');document:clearSelection()
assert(first_indent_char=='I','rendered indentation no longer contains four spaces')
local y5=select(2,position(5));local y6=select(2,position(6))
print(('positions x1=%d x2=%d y1=%d y2=%d y4=%d y5=%d y6=%d pages=%d'):format(x1,x2,y1,y2,y4,y5,y6,document:getPageCount()))
local view=document:getTextFromPositions({x=1,y=1},{x=Device.screen:getWidth()-2,y=Device.screen:getHeight()-2},true)
assert(view and view.text and view.text:find('STARTLINE',1,true) and view.text:find('INDENTLINE',1,true))
document:gotoPage(1);document:drawCurrentView(Device.screen.bb,0,0,Device.screen:getSize())
Device.screen:shot(evidence..'/txt-layout.png')
assert(indent_x>x1,'leading spaces were collapsed in the rendered text')
assert(y4-y2>y2-y1,'empty line did not add visible vertical space')
assert(y6-y5>y2-y1,'long line did not wrap')
document:close();print('PASS: TXT indentation, empty line and long-line wrapping')

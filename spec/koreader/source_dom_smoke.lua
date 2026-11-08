-- Packaged source/DOM mapping in the real engine and ReaderUI; local fixtures only.
require("setupkoenv")
local home, evidence = assert(os.getenv("KO_HOME")), assert(os.getenv("WEREAD_EVIDENCE"))
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
G_reader_settings:saveSetting("language", "zh_CN")
G_reader_settings:saveSetting("color_rendering", false)
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
require("gettext").changeLang("zh_CN")
local Device = require("device")
require("document/canvascontext"):init(Device)
local PluginLoader = require("pluginloader")
PluginLoader.enabled_plugins, PluginLoader.disabled_plugins, PluginLoader.loaded_plugins = {}, {}, {}
for _, entry in ipairs(PluginLoader:_discover()) do
    if entry.name == "weread" then PluginLoader:_load{ entry } end
end
assert(#PluginLoader.enabled_plugins == 1, "candidate plugin missing")
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path
local Content = require("weread.lib.content")
local settings = require("weread.lib.settings"):new()
assert(settings.mock_endpoint and settings.data_dir:match("/weread%-mock$"), "isolated profile required")
local Source = require('weread.lib.position_source')
local Identity = require('weread.lib.book_file_identity')
local Coordinates = require('weread.lib.source_coordinates')
local Dom = require('weread.lib.source_dom')
local chapters = {
    {chapterUid=11,chapterIdx=1,title='重复标题'}, {chapterUid=22,chapterIdx=2,title='重复标题'},
}
local parts={'<h1>重复标题</h1>'}
for i=1,80 do
    parts[#parts+1]='<p>段落'..i..'：窗外的风穿过树梢。'..string.rep('阅读位置应当对应正文，换页、字号和段落不会改变章节归属。',4)..'</p>'
end
parts[#parts+1]='<p>第一段末尾包含真实方括号[36]和空格 A &amp; B，以及表情😀。</p>'
parts[#parts+1]='<p>跨段唯一目标从这里开始，这是下一段的完整正文用于定位。</p>'
parts[#parts+1]='<p>重复前文甲。相同的句子重复两次但前后文字可以区分各自的位置。</p>'
parts[#parts+1]='<p>重复前文乙。相同的句子重复两次但前后文字可以区分各自的位置。</p>'
parts[#parts+1]='<p>章节结尾有独立的最终一句正文，用于检查最后边界。</p>'
parts[#parts+1]='<p style="page-break-before:always"><img src="https://weread.qq.com/mock/illustration.png"/></p>'
local body=table.concat(parts,'\n')
local raw='<html><body>'..body..'</body></html>'
local book={book_id='900001',bookId='900001',bookVersion=7,title='正文坐标 DOM 验证',chapters=chapters}
local sources={}
for _,chapter in ipairs(chapters) do sources[tostring(chapter.chapterUid)]=assert(Source.capture(book,chapter,raw,'web_xhtml')) end
local rendered=body:gsub('https://weread.qq.com/mock/illustration.png','../images/end.png')
local assets={{href='images/end.png',media_type='image/png',data=require('weread.lib.client'):new(settings):get_binary('https://weread.qq.com/mock/illustration.png')}}
local path=Content.save_book_epub(settings,book,chapters,{['11']=rendered,['22']=rendered},'full',assets,nil,nil,Identity.capture(book),sources)
Content.save_catalog_cache(require('weread.lib.client'):new(settings),settings,book,chapters)
settings:set('books',{['900001']=book}); settings:flush()
local UIManager=require('ui/uimanager')
local Event=require('ui/event')
local reader=require('apps/reader/readerui'):new{
    dimen=Device.screen:getSize(),document=require('document/documentregistry'):openDocument(path),
}
UIManager:show(reader)
local function flush()
    UIManager:shiftScheduledTasksBy(-1e9)
    UIManager:setInputTimeout(0)
    UIManager:handleInput()
end
flush()
local doc=reader.document
local final_page_xp=assert(doc:getPageXPointer(doc:getPageCount()))
local final_page_node=doc:getTextFromXPointer(final_page_xp)
assert(not final_page_node or Dom.normalize(final_page_node)=='','last page is not image-only')
local original=doc:getXPointer()
local map=assert(Coordinates.build(raw))
local point=assert(map:locate('跨段唯一目标从这里开始，这是下一段的完整正文用于定位。'))
local anchor=assert(map:anchor(point.co))
assert(not doc:findAllText(anchor.text,true,0,10,false,0),'fixture failed to cross native paragraph separators')
doc:clearSelection()
local index1,err=Dom.open(doc,'900001',11)
assert(index1,err)
local index2,err2=Dom.open(doc,'900001',22)
assert(index2,err2)
local first,why=index1:locate(point.co)
assert(first,why)
local second,why2=index2:locate(point.co)
assert(second,why2)
assert(first.xpointer~=second.xpointer and first.render_path~=second.render_path,'identical chapters conflated')
assert(doc:getXPointer()==original,'mapping changed viewport')
local captured,reason=index2:capture(second.xpointer)
assert(captured,reason)
assert(captured.co==point.co,'DOM to source did not round-trip exactly')
assert(reader:handleEvent(Event:new('GotoXPointer',second.xpointer)))
flush()
assert(doc:isXPointerInCurrentPage(second.xpointer),'second chapter target not visible')
local target_page=doc:getCurrentPage()
local early=assert(map:locate('段落5：窗外的风穿过树梢。阅读位置应当对应正文'))
local early_point,early_reason=index2:locate(early.co)
assert(early_point,early_reason)
local checkpoint_count=index2.stats.checkpoints
assert(checkpoint_count>20,'long chapter did not create sparse checkpoints')
local before_steps=index2.stats.steps
assert(index2:locate(early.co))
local repeated_steps=index2.stats.steps-before_steps
assert(repeated_steps<=Dom.CHECKPOINT_INTERVAL+100,'sparse checkpoint did not bound repeat walking')
local ending=assert(map:locate('章节结尾有独立的最终一句正文，用于检查最后边界。')).end_co
local final_point=assert(index2:locate(ending),'final chapter boundary unavailable')
assert(assert(index2:capture(final_point.xpointer)).co==ending,'final chapter point did not round-trip')
local repeated=assert(map:locate('相同的句子重复两次但前后文字可以区分各自的位置。','重复前文乙。'))
local repeated_point=assert(index2:locate(repeated.co))
assert(assert(index2:capture(repeated_point.xpointer)).co==repeated.co,'repeated paragraph context selected wrong occurrence')
local literal=assert(map:locate('真实方括号[36]和空格A&B，以及表情😀。'))
local literal_point=assert(index2:locate(literal.co))
assert(assert(index2:capture(literal_point.xpointer)).co==literal.co,'literal labels/entities/astral text moved coordinate')
-- Same DOM coordinates survive genuine font reflow and scroll mode.
local font_before=reader.font.configurable.font_size
local pages_before=doc:getPageCount()
assert(reader:handleEvent(Event:new('SetFontSize',font_before+4)))
flush()
assert(reader.font.configurable.font_size==font_before+4 and doc:getPageCount()~=pages_before,'font did not actually change pagination')
local reflow=assert(index2:locate(point.co))
assert(assert(index2:capture(reflow.xpointer)).co==point.co,'font reflow moved source point')
reader:handleEvent(Event:new('SetViewMode','scroll')); flush()
assert(reader:handleEvent(Event:new('GotoXPointer',reflow.xpointer))); flush()
assert(assert(index2:capture(reflow.xpointer)).co==point.co,'scroll capture moved source point')
UIManager:forceRePaint(); Device.screen:shot(evidence..'/source-dom-scroll.png')
local current=true
local cancellable,cancel_reason=Dom.open(doc,'900001',11,{is_current=function() return current end,
    yield=function() current=false end})
assert(cancellable==nil and cancel_reason=='source_dom/cancelled','cancelled preparation returned an index')
local active,armed=true,false
local walking=assert(Dom.open(doc,'900001',11,{is_current=function() return active end,
    yield=function() if armed then active=false end end}))
local current_pointer=doc:getXPointer()
armed=true
local aborted,abort_reason=walking:locate(early.co)
assert(not aborted and abort_reason=='source_dom/cancelled','native walk committed after cancellation')
active=true
assert(not walking:locate(early.co),'cancelled native index revived')
assert(doc:getXPointer()==current_pointer,'cancelled native mapping changed viewport')
local result={status='PARTIAL',public_network_used=false,production_account_writes_attempted=0,
    progress_mapping_enabled=false,wire_progress_write_verified=false,co=point.co,
    chapters=2,duplicate_titles=true,identical_chapter_text=true,cross_block=true,
    source_dom_source_roundtrip=true,font_reflow=true,scroll=true,literal_brackets=true,entities=true,astral=true,
    chapter_end=true,image_only_last_page=true,repeat_context_disambiguation=true,cancel_preparation=true,cancel_walk=true,repeat_walk_steps=repeated_steps,sparse_checkpoints=checkpoint_count,target_page=target_page,
    font_before=font_before,font_after=reader.font.configurable.font_size,pages_before=pages_before,pages_after=doc:getPageCount(),
    screen={width=Device.screen:getWidth(),height=Device.screen:getHeight()}}
local file=assert(io.open(evidence..'/source-dom.json','wb'))
file:write(require('rapidjson').encode(result));file:close()
reader:onClose(); UIManager:quit()
print('PASS: chapter-bound normalized DOM <-> source co; cross-block, identical chapters, final boundary, font reflow and scroll')

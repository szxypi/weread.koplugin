-- Synthetic media notes in the actual plugin/CREngine/ReaderLink runtime.
local repo, evidence = assert(arg[1]), assert(arg[2])
local home = assert(os.getenv('KO_HOME'))
require('setupkoenv')
io.stdout:setvbuf('no')
package.path = repo .. '/?.lua;' .. package.path
G_defaults = require('luadefaults'):open()
G_defaults:saveSetting('DCREREADER_VIEW_MODE','scroll')
G_reader_settings = require('luasettings'):open(home .. '/settings.reader.lua')
for key, value in pairs({ language='zh_CN', color_rendering=false, footnote_link_in_popup=true,
    tap_to_follow_links=true, copt_font_size=24, copt_view_mode=1, extra_plugin_paths={home .. '/plugins'} }) do
    G_reader_settings:saveSetting(key, value)
end
require('gettext').changeLang('zh_CN')
require('ui/bidi').setup('zh_CN')
local Device = require('device')
require('document/canvascontext'):init(Device)
assert(require('weread.lib.mock_environment').save{
    enabled=true, host='127.0.0.1', port=assert(tonumber(os.getenv('WEREAD_MOCK_PORT'))),
})
local Loader = require('pluginloader')
Loader.enabled_plugins, Loader.disabled_plugins, Loader.loaded_plugins = {}, {}, {}
for _i, entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path = repo .. '/?.lua;' .. package.path
local UIManager = require('ui/uimanager')
local Screen = Device.screen
local Geom=require('ui/geometry')
local ReaderUI = require('apps/reader/readerui')
local Registry = require('document/documentregistry')
local Content = require('weread.lib.content')
local Identity=require('weread.lib.book_file_identity')
local json=require('json')
local chapters={{chapterUid=1,chapterIdx=1,title='滚动正文',files={'Text/body.xhtml'},wordCount=2000},
    {chapterUid=2,chapterIdx=2,title='滚动图注',files={'Text/notes.xhtml'},wordCount=2000}}
local book={bookId='900001',title='独立章节滚动验证',bookVersion=7,wordCount=4000,cache_dir=evidence .. '/cache'}
local body=string.rep('<p>自写正文，滚动到图注链接附近。</p>',20)
    .. '<p id="ref">原文<a href="notes.xhtml#note">查看图注</a></p>'
    .. string.rep('<p>链接之后的合成正文，保留足够滚动空间。</p>',80)
local notes=string.rep('<p>自写注释，图注前的合成文字。</p>',20)
    .. '<p id="note">合成图注 <a href="body.xhtml#ref">原文返回</a></p>'
    .. '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="60"><rect width="90" height="50" fill="black"/></svg>'
    .. string.rep('<p>图注后的合成文字。</p>',80)
local path=Content.save_chapter_epub({},book,chapters[1],body,{},'',Identity.capture(book))
local target_path=Content.save_chapter_epub({},book,chapters[2],notes,{},'',Identity.capture(book))
local settings=require('weread.lib.settings'):new()
book.cached_chapters={['1']=path,['2']=target_path};book.chapters=chapters
settings:set('books',{['900001']=book})
assert(Content.save_catalog_cache({json_encode=function(_self,value) return json.encode(value) end},settings,book,chapters))
settings:set('sync',{pull_on_open=false,upload_on_close=false})
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.show_annotations=false;settings:set('cache',cache)
settings:flush()
local reader,source_point,target_point
local closed_host,closed_worker
local receipts={}
local function snapshot()
    return {pos=reader.document:getCurrentPos(),xpointer=reader.rolling.xpointer,mode=reader.view.view_mode,
        rendering_hash=reader.document:getDocumentRenderingHash(true)}
end
local function write(name,value)
    local file=assert(io.open(evidence .. '/' .. name,'wb'));assert(file:write(json.encode(value)));file:close()
end
local function arrived(file)
    reader=ReaderUI.instance
    return reader and reader.document and reader.document.file==file and reader.weread
        and reader.weread._chapter_links and not reader.weread._chapter_link_job
end
local function scroll(pos)
    assert(reader.view.view_mode=='scroll','fixture is not in native scroll mode')
    reader.rolling:_gotoPos(pos);reader.rolling.xpointer=reader.document:getXPointer()
end
local function tap()
    local visible={}
    for _i,link in ipairs(reader.document:getPageLinks()) do
        if link.segments and #link.segments>0 then visible[#visible+1]=link end
    end
    local rect=assert(visible[1],'missing visible scroll link').segments[1]
    local gesture={pos=Geom:new{x=math.floor((rect.x0+rect.x1)/2),y=math.floor((rect.y0+rect.y1)/2)}}
    local actual=assert(reader.link:getLinkFromGes(gesture),'native scroll gesture missed link')
    reader.link:onTap(nil,gesture);return actual
end
local steps={function()
    reader=ReaderUI:new{dimen=Screen:getSize(),document=Registry:openDocument(path)}
    UIManager:show(reader)
end,function()
    assert(arrived(path));assert(reader.view.view_mode=='scroll')
    local at=reader.document:getPosFromXPointer('#_doc_fragment_0_ ref')
    scroll(at-73);source_point=snapshot();tap()
end,function()
    if not arrived(target_path) then return false end
    assert(reader.rolling.xpointer=='#_doc_fragment_0_ note')
    scroll(reader.document:getCurrentPos()+37);target_point=snapshot()
    assert(reader.link:onGoBackLink(true))
end,function()
    if not arrived(path) then return false end
    local actual=snapshot();write('scroll-back-observation.json',{expected=source_point,actual=actual})
    assert(actual.mode=='scroll' and actual.pos==source_point.pos,'scroll Back lost exact pixel viewport')
    assert(actual.xpointer==source_point.xpointer,'scroll Back lost native pointer')
    receipts.scroll_back_exact=true
    assert(reader.link:onGoForwardLink())
end,function()
    if not arrived(target_path) then return false end
    local actual=snapshot();write('scroll-forward-observation.json',{expected=target_point,actual=actual})
    assert(actual.mode=='scroll' and actual.pos==target_point.pos and actual.xpointer==target_point.xpointer,'scroll Forward lost exact viewport')
    receipts.scroll_forward_exact=true
    reader.link:onGoBackLink()
end,function()
    if not arrived(path) then return false end
    assert(reader.document:getCurrentPos()==source_point.pos)
    UIManager:forceRePaint();Screen:shot(evidence .. '/chapter-scroll-return.png')
    tap()
    local host=reader.weread
    assert(host._chapter_link_job and host._chapter_link_job.worker.job,'suspend fixture did not start actual worker')
    local worker=host._chapter_link_job.worker
    host:onSuspend()
    assert(not host._chapter_link_job and not worker.job,'suspend did not cancel actual worker')
    host:onResume()
end,function()
    assert(arrived(path) and reader.document:getCurrentPos()==source_point.pos,'resume applied an old result')
    receipts.suspend_worker_cancelled=true;receipts.resume_does_not_replay=true
    tap()
    reader.view:onSetViewMode('page')
    assert(not reader.weread._chapter_link_job,'mode change did not cancel old link')
    reader.view:onSetViewMode('scroll')
end,function()
    assert(arrived(path),'mode change opened a stale file')
    receipts.mode_change_cancellation=true
    scroll(source_point.pos);tap()
    closed_host=reader.weread;closed_worker=closed_host._chapter_link_job.worker
    reader:onClose(false);reader:showFileManager(path);reader=nil
    assert(not closed_host._chapter_link_job and not closed_worker.job,'close did not cancel worker')
end,function()
    assert(not ReaderUI.instance,'late closed result reopened reader')
    receipts.close_worker_cancelled=true;receipts.closed_result_does_not_reopen=true
    reader=ReaderUI:new{dimen=Screen:getSize(),document=Registry:openDocument(path)}
    UIManager:show(reader)
end,function()
    assert(arrived(path),'fresh reader hooks missing')
    scroll(source_point.pos);source_point=snapshot();tap()
end,function()
    if not arrived(target_path) then return false end
    receipts.fresh_reader_navigation=true
    -- Persist a real per-book font change while the other chapter is open.
    local doc_settings=require('docsettings'):open(path)
    doc_settings:saveSetting('copt_font_size',40);doc_settings:flush()
    assert(reader.link:onGoBackLink(true))
end,function()
    if not arrived(path) then return false end
    local actual=snapshot()
    assert(actual.rendering_hash~=source_point.rendering_hash,'native reflow fixture did not change layout')
    assert(actual.xpointer==source_point.xpointer,'reflow lost verified native text point')
    assert(actual.pos==reader.document:getPosFromXPointer(source_point.xpointer),'reflow reused incompatible pixel position')
    assert(actual.pos~=source_point.pos,'reflow fixture did not distinguish old pixel position')
    write('scroll-reflow-observation.json',{expected_text=source_point,actual=actual})
    receipts.changed_layout_uses_text_anchor=true
    assert(not reader.weread.progress_sync.verified,'local scroll restoration granted cloud verification')
    receipts.no_cloud_verification_grant=true
    UIManager:forceRePaint();Screen:shot(evidence .. '/chapter-scroll-reflow.png')
    reader:onClose();reader=nil
end}
local failure,index,started=nil,1,os.time()
local function advance()
    if not steps[index] then UIManager:quit();return end
    if os.time()-started>75 then failure='step timeout ' .. index;UIManager:quit();return end
    local ok,value=xpcall(steps[index],debug.traceback)
    if not ok then failure='step ' .. index .. ': ' .. value;UIManager:quit();return end
    if value~=false then index=index+1;started=os.time() end
    UIManager:scheduleIn(index==2 and 2 or 0.3,advance)
end
advance();UIManager:run();assert(not failure,failure)
assert(index>#steps,'scroll fixture stopped early')
receipts.result='PASS';receipts.synthetic_only=true;receipts.real_account_requests=0
write('chapter-scroll-result.json',receipts)
print('PASS: standalone scroll exact Back/Forward')

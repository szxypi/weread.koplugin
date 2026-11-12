-- Synthetic media notes in the actual plugin/CREngine/ReaderLink runtime.
local repo, evidence = assert(arg[1]), assert(arg[2])
local home = assert(os.getenv('KO_HOME'))
require('setupkoenv')
io.stdout:setvbuf('no')
package.path = repo .. '/?.lua;' .. package.path
G_defaults = require('luadefaults'):open()
G_reader_settings = require('luasettings'):open(home .. '/settings.reader.lua')
for key, value in pairs({ language='zh_CN', color_rendering=false, footnote_link_in_popup=true,
    tap_to_follow_links=true, copt_font_size=24, extra_plugin_paths={home .. '/plugins'} }) do
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
local Geom = require('ui/geometry')
local ReaderUI = require('apps/reader/readerui')
local Registry = require('document/documentregistry')
local Footnotes = require('weread.lib.footnotes')
local Content = require('weread.lib.content')
local Guard = require('weread.lib.rich_footnotes')
local native_extract = Guard.requires_original
local extracts = {}
Guard.requires_original = function(html)
    extracts[#extracts+1]=html
    local file=assert(io.open(evidence .. '/synthetic-extracts.json', 'wb'))
    file:write(require('json').encode(extracts)); file:close()
    return native_extract(html)
end
local chapter = {chapterUid=179, chapterIdx=1, title='复杂脚注验证'}
local source = '<p>点击查看：<a epub:type="noteref" href="#image">[图]</a> '
    .. '<a epub:type="noteref" href="#formula">[式]</a> '
    .. '<a epub:type="noteref" href="#table">[表]</a> '
    .. '<a epub:type="noteref" href="#citation">[引]</a> '
    .. '<a epub:type="noteref" href="#plain">[文]</a></p>'
    .. string.rep('<p>正文用于检查从注释返回以后仍停留在原来的阅读位置。</p>', 38)
    .. '<aside id="image" epub:type="footnote"><p>图注：黑框圆形应完整显示。</p>'
    .. '<img src="../images/note.svg" width="240" height="120" alt="注释示意图"/></aside>'
    .. '<aside id="formula" epub:type="footnote"><p>公式注释：分数和平方根。</p>'
    .. '<math xmlns="http://www.w3.org/1998/Math/MathML" display="block"><mfrac><mi>a</mi><mi>b</mi></mfrac>'
    .. '<mo>=</mo><msqrt><mi>x</mi></msqrt></math></aside>'
    .. '<aside id="table" epub:type="footnote"><p>表格注释：两列两行。</p>'
    .. '<table style="border-collapse:collapse"><tr><th>项目</th><th>数值</th></tr>'
    .. '<tr><td>甲</td><td>17</td></tr><tr><td>乙</td><td>29</td></tr></table></aside>'
    .. '<aside id="citation" epub:type="footnote"><p>引用注释：<a href="#reference">查看资料</a></p></aside>'
    .. '<aside id="plain" epub:type="footnote"><p>纯文字仍在原生弹窗显示。</p></aside>'
    .. string.rep('<p>参考资料之前的正文。</p>', 35)
    .. '<p id="reference">引用资料：这是可继续点击阅读的目标。</p>'
local scan = Footnotes.scan_chapter(source, chapter)
local body, stats = Footnotes.transform_chapter(source, scan,
    Footnotes.build_book_index({['179']=scan}, {chapter}))
assert(stats.converted==1 and stats.removed_note_blocks==1)
for _i, tag in ipairs({'<img ', '<math ', '<table ', 'href="#reference"'}) do
    assert(body:find(tag, 1, true), 'media was lost during conversion')
end
local assets={{href='images/note.svg', media_type='image/svg+xml', data=
    '<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120"><rect x="2" y="2" width="236" height="116" fill="white" stroke="black" stroke-width="4"/><circle cx="120" cy="60" r="40" fill="black"/></svg>'}}
local css=Footnotes.FOOTNOTES_CSS .. '\ntd,th{border:1px solid black;padding:0.3em;}'
local path = Content.save_chapter_epub({}, {bookId='990179', title='复杂脚注', cache_dir=evidence .. '/single-chapter'},
    chapter, body, assets, css)
local cross_chapters={{chapterUid=180,title='正文',files={'Text/body.xhtml'}},
    {chapterUid=181,title='原始复杂注释',files={'Text/notes.xhtml'}},
    {chapterUid=182,title='引用资料',files={'Text/资料 100%.xhtml'}}}
local cross_source='<p>跨章原注释<a id="source-ref" epub:type="noteref" href="../Text/notes.xhtml#remote-rich">[图式表]</a></p>'
    .. string.rep('<p>阅读正文，跨章注释不应被复制成纯文字。</p>',25)
local cross_note='<aside id="remote-rich" epub:type="footnote"><p>跨章复杂注释：保留图片、分数、根式和表格。</p>'
    .. '<img src="../images/note.svg" width="240" height="120"/>'
    .. '<math xmlns="http://www.w3.org/1998/Math/MathML"><mfrac><mi>a</mi><mi>b</mi></mfrac>'
    .. '<mo>=</mo><msqrt><mi>x</mi></msqrt></math>'
    .. '<table><tr><th>项目</th><th>数值</th></tr><tr><td>甲</td><td>17</td></tr><tr><td>乙</td><td>29</td></tr></table>'
    .. '<p><a role="doc-backlink" href="body.xhtml#source-ref">返回正文</a> '
    .. '<a href="%E8%B5%84%E6%96%99%20100%25.xhtml#%E6%9D%90%E6%96%99%26%E8%AF%B4%E6%98%8E">查看资料</a> '
    .. '<a href="body.xhtml#source-ref">[1]</a></p></aside>'
    .. '<p id="source-ref">本章同名锚点，不应被误选为正文。</p>'
local cross_reference='<p id="材料&amp;说明">真正的引用资料：中文和转义锚点。'
    .. '<a href="notes.xhtml#remote-rich">返回注释</a></p>'
local cross_scans={['180']=Footnotes.scan_chapter(cross_source,cross_chapters[1]),
    ['181']=Footnotes.scan_chapter(cross_note,cross_chapters[2]),
    ['182']=Footnotes.scan_chapter(cross_reference,cross_chapters[3])}
local cross_index=Footnotes.build_book_index(cross_scans,cross_chapters,
    {['180']='chapter-001.xhtml',['181']='chapter-002.xhtml',['182']='chapter-003.xhtml'})
local cross_body,cross_stats=Footnotes.transform_chapter(cross_source,cross_scans['180'],cross_index)
assert(cross_stats.converted==0 and cross_stats.native_links==1)
local rendered_note,note_stats=Footnotes.transform_chapter(cross_note,cross_scans['181'],cross_index)
local rendered_reference=Footnotes.transform_chapter(cross_reference,cross_scans['182'],cross_index)
assert(note_stats.converted==0 and note_stats.native_links==3)
local cross_path=Content.save_book_epub({}, {bookId='990180',title='跨章复杂脚注',cache_dir=evidence .. '/cross-chapter'},
    cross_chapters,{['180']=cross_body,['181']=rendered_note,['182']=rendered_reference},'full',assets,css)
local reader, origin
local settings = require('weread.lib.settings'):new()
settings:set('books', {['990179']={bookId='990179', title='复杂脚注', cached_file=path, cache_dir=evidence .. '/single-chapter', chapters={chapter}},
    ['990180']={bookId='990180',title='跨章复杂脚注',cached_file=cross_path,cache_dir=evidence .. '/cross-chapter',chapters=cross_chapters}})
settings:flush()
local function shot(name)
    UIManager:forceRePaint(); Screen:shot(evidence .. '/' .. name .. '.png')
end
local function popup()
    for widget in UIManager:topdown_widgets_iter() do
        if widget.html and widget.htmlwidget then return widget end
    end
end
local function visible_links()
    local result={}
    for _i,link in ipairs(reader.document:getPageLinks()) do
        if link.segments and #link.segments>0 then result[#result+1]=link end
    end
    return result
end
local function tap(index)
    local link = assert(visible_links()[index], 'missing link ' .. index)
    local rect = assert(link.segments[1])
    local gesture={pos=Geom:new{x=math.floor((rect.x0+rect.x1)/2), y=math.floor((rect.y0+rect.y1)/2)}}
    local chosen=assert(reader.link:getLinkFromGes(gesture))
    reader.link:onTap(nil,gesture)
    return chosen.xpointer
end
local steps = {function()
    reader = ReaderUI:new{dimen=Screen:getSize(), document=Registry:openDocument(path)}
    assert(reader.weread)
    assert(reader.weread._current_weread_book_id=='990179')
    UIManager:show(reader)
    reader.styletweak:onToggleStyleTweak({'footnote-inpage_epub', false}, nil, true)
    reader.rolling:onGotoPage(1)
end, function()
    origin = reader.document:getXPointer()
    shot('00-rich-references')
end}
for index, name in ipairs({'image', 'formula', 'table', 'citation'}) do
    steps[#steps+1] = function()
        tap(index)
        if popup() then shot('failure-' .. name .. '-popup') end
        assert(not popup(), 'rich ' .. name .. ' was routed into a lossy popup')
        assert(reader:getCurrentPage()>1, 'rich note did not navigate to original content')
        shot('0' .. index .. '-original-' .. name)
    end
    if name=='citation' then
        steps[#steps+1] = function()
            local links = reader.document:getPageLinks()
            assert(#links==1, 'expected one original citation link on this page')
            local target = reader.document:getHTMLFromXPointer(links[1].section, 0x1001, true)
            assert(target:find('引用资料', 1, true), 'citation points to another target')
            local page=reader:getCurrentPage()
            tap(1)
            assert(reader:getCurrentPage()>page)
            shot('05-citation-target')
            reader.link:onGoBackLink()
        end
    end
    steps[#steps+1] = function()
        reader.link:onGoBackLink()
        assert(reader.document:getXPointer()==origin, 'return lost the reading position')
    end
end
steps[#steps+1] = function()
    tap(5)
    local view = assert(popup(), 'plain note no longer opens the native popup')
    assert(view.html:find('纯文字仍在原生弹窗显示', 1, true))
    assert(reader.document:getXPointer()==origin)
    shot('06-plain-popup'); view:onClose()
    local state=assert(reader.weread._rich_footnote_guard, 'native reader guard was not attached')
    local plugin=reader.weread
    reader:onClose()
    assert(not plugin._rich_footnote_guard and state.link.showAsFootnotePopup==state.original
        and state.link.onGotoLink==state.goto_original,
        'closing the document left a native handler patched')
    reader=ReaderUI:new{dimen=Screen:getSize(),document=Registry:openDocument(cross_path)}
    assert(reader.weread._current_weread_book_id=='990180')
    UIManager:show(reader)
    reader.styletweak:onToggleStyleTweak({'footnote-inpage_epub',false},nil,true)
    reader.rolling:onGotoPage(1)
end
steps[#steps+1]=function()
    origin=reader.document:getXPointer()
    tap(1)
    assert(not popup() and reader:getCurrentPage()>1, 'cross-chapter original was not opened')
    shot('07-cross-chapter-original')
end
steps[#steps+1]=function()
    local links=visible_links()
    local detail={}
    for _i,link in ipairs(links) do detail[_i]={section=link.section,uri=link.uri,segments=link.segments,
        native_target_exists=reader.document:isXPointerInDocument(link.section)} end
    local file=assert(io.open(evidence .. '/synthetic-cross-links.json','wb'))
    file:write(require('json').encode(detail));file:close()
    assert(#links==3,'expected two original return links and one citation')
    local target='#_doc_fragment_2_ 材料&说明'
    assert(reader.document:isXPointerInDocument(target),'literal original anchor is unavailable')
    local text=reader.document:getHTMLFromXPointer(target,0x1001,true)
    assert(text:find('真正的引用资料',1,true),'encoded citation points to the wrong chapter')
    tap(2)
    assert(not popup() and reader.rolling.xpointer==target,'citation target not followed exactly')
    shot('08-cross-citation')
end
steps[#steps+1]=function()
    assert(#visible_links()==1,'expected one return to the note')
    local target=tap(1)
    assert(not popup() and reader.rolling.xpointer==target,'second-hop return not followed exactly')
    shot('09-cross-note-return')
end
steps[#steps+1]=function()
    local target=tap(1)
    assert(not popup() and reader.rolling.xpointer==target and reader:getCurrentPage()==1,
        'typed original backlink selected a different chapter or anchor')
    shot('10-cross-body-return')
end
steps[#steps+1]=function()
    tap(1)
    local target=tap(3)
    assert(not popup() and reader.rolling.xpointer==target and reader:getCurrentPage()==1,
        'implicit original backlink selected the same-name local anchor')
    shot('11-cross-implicit-return')
end
steps[#steps+1]=function()
    -- Clear the deliberate multi-hop history and independently verify the
    -- existing native Back behavior from the original reading view.
    reader.rolling:onGotoPage(1)
    origin=reader.document:getXPointer()
    tap(1)
    reader.link:onGoBackLink()
    assert(reader.document:getXPointer()==origin, 'cross-chapter return lost reading position')
    reader:onClose();reader=nil
end
local failure, index = nil, 0
local function advance()
    index=index+1
    if not steps[index] then UIManager:quit(); return end
    local ok, err = xpcall(steps[index], debug.traceback)
    if not ok then failure=err; shot('failure'); UIManager:quit(); return end
    UIManager:scheduleIn(index==1 and 3 or 0.6, advance)
end
advance(); UIManager:run()
assert(not failure, failure)
assert(index>=#steps, 'simulator stopped before all steps completed')
local result = assert(io.open(evidence .. '/rich-footnotes-result.json', 'wb'))
assert(result:write(require('json').encode{result='PASS', synthetic_only=true,
    original_media_notes=4, exact_returns=4, citation_followed=true, plain_native_popup=true,
    cross_chapter_rich_original=true,cross_chapter_exact_return=true,
    cross_chapter_citation=true,unicode_encoded_anchor=true,typed_backlink_exact=true,
    implicit_backlink_exact=true,second_hop_return_exact=true}))
result:close()
print('PASS: native rich footnote originals, citation navigation and exact return; plain popup retained')

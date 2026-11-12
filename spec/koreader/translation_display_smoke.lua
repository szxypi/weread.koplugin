-- Packaged display model and real CRE renderer, with synthetic EPUBs only.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Content=require('weread.lib.content')
local Model=require('weread.lib.translation')
local settings=require('weread.lib.settings'):new()
assert(settings.mock_endpoint and settings.data_dir:match('/weread%-mock$'))
local chapters={{chapterUid=1,chapterIdx=1,title='Chapter One',wordCount=1000},{chapterUid=2,chapterIdx=2,title='Chapter Two',wordCount=1000}}
local bodies={['1']=[[<html><body><h1>Chapter One</h1>
<p id="pair">ORIGINALONE English paragraph.</p><p id="pair" class="wr-translation">TRANSLATIONONE 中文译文。</p>
<p>NOIDORIGINAL English paragraph.</p><p class="wr-translation">NOIDTRANSLATION 中文译文。</p>
<p id="keep">KEEPORIGINAL unpaired source.</p><p id="other" class="wr-translation">ORPHANTRANSLATION 保留原文。</p>
<p>LINKORIGINAL <a href="#note">footnote</a></p><p class="wr-translation">LINKTRANSLATION 保留链接。</p>
<p id="note">Note text.</p></body></html>]],
['2']=[[<html><body><h1>Chapter Two</h1><p id="pair">ORIGINALTWO Same ID in another chapter.</p>
<p id="pair" class="wr-translation">TRANSLATIONTWO 第二章译文。</p></body></html>]]}
local profile={blocks=0,chapters={}}
for index,chapter in ipairs(chapters) do
    local row=assert(Model.analyze(bodies[tostring(chapter.chapterUid)],tostring(chapter.chapterUid),index))
    profile.chapters[index]=row;profile.blocks=profile.blocks+row.blocks
end
assert(profile.blocks==5 and #profile.chapters[1].pairs==2 and #profile.chapters[2].pairs==1,'synthetic pairing boundary wrong')
local status=Model.translation_only_status(profile)
assert(status.available and status.unpaired==2 and status.reason=='partial','unpaired content boundary wrong')
local results={}
local function visible(document,page)
    document:gotoPage(page)
    local value=document:getTextFromPositions({x=1,y=1},{x=Device.screen:getWidth()-2,y=Device.screen:getHeight()-2},true)
    return value and value.text or ''
end
for _,mode in ipairs({'original','bilingual','translation'}) do
    local book={book_id='900001',title='Synthetic translation '..mode,author='Synthetic',chapters=chapters}
    local path=Content.save_book_epub(settings,book,chapters,bodies,mode)
    local document=assert(require('document/documentregistry'):openDocument(path))
    assert(document:loadDocument())
    document:setFontFace('Noto Sans CJK SC');document:setupFallbackFontFaces()
    local css=assert(Model.css(profile,mode,100))
    document:setStyleSheet(document.default_css,css);document:setFontSize(Device.screen:scaleBySize(22));document:render()
    assert(document:getPageCount()==2,'unexpected synthetic chapter pagination')
    local first,second=visible(document,1),visible(document,2)
    local function contains(value,word) return value:find(word,1,true)~=nil end
    assert(contains(first,'ORIGINALONE')==(mode~='translation'),'shared ID source visibility wrong')
    assert(contains(first,'NOIDORIGINAL')==(mode~='translation'),'id-less source visibility wrong')
    assert(contains(first,'TRANSLATIONONE')==(mode~='original') and contains(first,'NOIDTRANSLATION')==(mode~='original'),
        'translation visibility wrong')
    assert(contains(first,'KEEPORIGINAL') and contains(first,'LINKORIGINAL'),'unpaired source or link control disappeared')
    assert(contains(second,'ORIGINALTWO')==(mode~='translation') and contains(second,'TRANSLATIONTWO')==(mode~='original'),
        'fragment scope or reused source ID affected wrong chapter')
    local old='/body/DocFragment[1]/body/p[1]/text().3'
    local target=Model.remap_xpointer(profile,old,mode) or old
    assert(document:isXPointerInDocument(target),'remapped paragraph not in native DOM')
    if mode=='translation' then
        assert(target=='/body/DocFragment[1]/body/p[2]','translation target copied text offset across languages')
        local live=document:getNextVisibleChar('/body/DocFragment[1]/body/p[1].0')
        assert(live and live:find('/p[2]',1,true),'hidden original did not resolve to paired visible translation')
    end
    document:gotoPage(1);document:drawCurrentView(Device.screen.bb,0,0,Device.screen:getSize())
    Device.screen:shot(evidence..'/translation-'..mode..'.png')
    results[#results+1]={mode=mode,pages=2,shared_id_and_idless_visibility=true,unpaired_original_preserved=true,
        link_original_preserved=true,fragment_scope_verified=true,native_target_valid=true}
    document:close()
end
local report={result='PASS',synthetic_only=true,native_engine=true,reader_menu_integrated=false,mode_persistence_integrated=false,
    epub_rewrite_required=false,fragments=2,translation_blocks=5,paired_blocks=3,unpaired_blocks=2,network_requests=0,modes=results}
local file=assert(io.open(evidence..'/translation-display.json','w'));file:write(require('json').encode(report));file:close()
print('PASS: packaged translation display model -> actual CRE original/bilingual/translation modes; fragment scopes, shared/id-less pairs, preserved unpaired/link content and native paragraph remap')

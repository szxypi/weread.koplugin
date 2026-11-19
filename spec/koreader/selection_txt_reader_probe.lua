-- Synthetic TXT source and actual native ReaderUI; never accesses an account.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local requests=0;local Client=require('weread.lib.client')
function Client:request() requests=requests+1;error('synthetic_network_forbidden',0) end
local Settings=require('weread.lib.settings');local Content=require('weread.lib.content')
local Source=require('weread.lib.position_source');local Identity=require('weread.lib.book_file_identity')
local Coordinates=require('weread.lib.source_coordinates');local Dom=require('weread.lib.source_dom')
local Context=require('weread.lib.source_context');local Quote=require('weread.lib.selection_txt_quote')
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local reopen=os.getenv('WEREAD_TXT_SELECTION_REOPEN')=='1'
local raw='A self-authored test begins with one emoji: 😀.\n'
    ..'A unique synthetic passage for testing a plain text highlight.\n'
    ..'A second distinct sentence supplies enough context for the native endpoint.\n'
local expected='A unique synthetic passage for testing a plain text highlight.'
local chapters={{chapterUid='1',chapterIdx=1,title='Synthetic',wordCount=100}}
local book={book_id='CB_SyntheticTxt',bookId='CB_SyntheticTxt',title='Synthetic',bookVersion=1,chapters=chapters}
local settings=Settings:new();local file
local cache=home..'/synthetic-txt-selection.json';local json=require('json');local Crypto=require('weread.lib.crypto')
if reopen then
    local input=assert(io.open(cache,'rb'));local saved=json.decode(input:read('*a'));input:close()
    assert(type(saved.file)=='string' and saved.file:sub(1,#home+1)==home..'/');file=saved.file
    local epub=assert(io.open(file,'rb'));local bytes=epub:read('*a');epub:close()
    assert(Crypto.sha256_hex(bytes)==saved.sha)
else
    local source=assert(Source.capture(book,chapters[1],raw,'web_txt'))
    file=assert(Content.save_book_epub(settings,book,chapters,{['1']=Content.txt_to_xhtml(raw)},'txt-selection',
        {},nil,nil,Identity.capture(book),{['1']=source}))
    local epub=assert(io.open(file,'rb'));local bytes=epub:read('*a');epub:close()
    local output=assert(io.open(cache,'wb'));output:write(json.encode({file=file,sha=Crypto.sha256_hex(bytes)}));output:close()
end
local Reader=require('apps/reader/readerui');local Document=require('document/documentregistry')
local reader=Reader:new{dimen=Device.screen:getSize(),document=assert(Document:openDocument(file))}
UI:show(reader);UI:shiftScheduledTasksBy(-1e9);UI:handleInput();UI:forceRePaint()
local map=assert(Coordinates.build(raw,{format='web_txt'}));local source_match=assert(map:locate(expected))
local index=assert(Dom.open(reader.document,book.book_id,'1'))
local first,last=assert(index:locate(source_match.co)),assert(index:locate(source_match.end_co))
local text=assert(reader.document:getTextFromXPointers(first.xpointer,last.xpointer));reader.document:clearSelection()
assert(Dom.normalize(text)==Dom.normalize(expected))
local location=assert(Context.location(reader.document,reader.view.view_mode))
local function capture(point)
    return Context.capture(reader.document,book.book_id,{xpointer=point.xpointer,page=location.page,pos=location.pos,
        view_mode=location.view_mode})
end
local a,b=capture(first),capture(last);assert(not a.error and not b.error)
assert(a.book_id==book.book_id and b.book_id==book.book_id and a.chapter_uid=='1' and b.chapter_uid=='1'
    and a.file==file and b.file==file and a.metadata==b.metadata and a.render_path==b.render_path)
local result=assert(Quote.project_context(raw,a,b,text))
assert(result.range=='47-109' and result.abstract==expected and requests==0)
print('\nWEREAD_TXT_SELECTION_READER='..json.encode({result='PASS',native_context=true,
    raw_range=true,book_bound=true,network_requests=requests,reopened=reopen}))
os.exit(0)

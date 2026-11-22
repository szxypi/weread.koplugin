-- Exercise the actual prefetch dispatcher, worker process and EPUB reader.
require('jit').off()
require('ffi').log=function() end
require('setupkoenv')
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
local Device=require('device')
require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local logger={info=function() end,warn=function() end,err=function() end,dbg=function() end}
logger.scoped=function() return logger end
package.loaded['weread.lib.logger']=logger
local json=require('json')
local input=json.decode(assert(io.stdin:read('*a')))
local owner=input.owner==true
assert(owner and os.getenv('WEREAD_OWNER_NATIVE_CANDIDATE_TMPFS')=='1' or
    not owner and os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local scope={vid=input.credentials.vid,epoch=1}
local book_id,uid=owner and assert(input.book_id) or '42',owner and assert(input.uid) or '37'
local book={book_id=book_id,bookVersion=owner and input.book_version or 1,title='Temporary book',author='Fixture'}
local chapter={chapterUid=uid,chapterIdx=1,title='Temporary chapter'}
local values={cache={download_book_images=true,native_chapter_resources=true},books={[book_id]=book}}
local settings={mock_endpoint=not owner and input.mock_endpoint or nil,cache_dir=home..'/books',data_dir=home,
    get=function(_,key,default) return values[key] or default end,
    set=function(_,key,value) values[key]=value end,flush=function() end,
    is_cookie_configured=function() return true end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_,s) return s==scope end}
local lfs=require('libs/libkoreader-lfs')
assert(lfs.mkdir(settings.cache_dir));assert(lfs.mkdir(home..'/workers'))
local store={read=function() return input.credentials,1,nil,false end}
local access=require('weread.lib.native_read_access')
local capture=access.capture
access.capture=function(s,existing) return capture(s,existing or store) end
local client=require('weread.lib.client'):new(settings)
if owner then
    local request=client.request
    client.request=function(self,options)
        assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
        local url=options.url
        assert((url:match('^https://i%.weread%.qq%.com/book/info%?') and options.method=='GET')
            or (url=='https://i.weread.qq.com/book/chapterInfos' and options.method=='POST')
            or (url:match('^https://i%.weread%.qq%.com/book/chapterdownload%?') and options.method=='GET'
                and url:find('stopAutoPayWhenBNE=1',1,true))
            or (require('weread.lib.native_chapter_remote').allowed(url)==url and options.method=='GET'
                and not options.headers.vid and not options.headers.accessToken))
        return request(self,options)
    end
end
local body=input.web
if not owner then
    body='<html><body><img src="https://img.qq.com/image.png?a=1&amp;b=2"/>'
    for i=1,80 do body=body..'<p>Native source integrated marker '..i..' synthetic text.</p>' end
    body=body..'</body></html>'
    if input.multi_css then
        body=body:gsub('<html><body>','<html><head><link rel="stylesheet" href="../style/b.css"/>'
            ..'<link rel="stylesheet" href="../style/a.css"/></head><body>',1)
    end
end
assert(type(body)=='string' and #body<=2*1024*1024)
local Content=require('weread.lib.content')
local Position=require('weread.lib.position_source')
Content.ensure_reader_state=function() end
Content.fetch_single_chapter_source=function(_,_,b,c,state)
    state.css='web-fallback';local web=body..(input.mismatch and '<!-- different -->' or '')
    return web,assert(Position.capture(b,c,web,'web_xhtml'))
end
Content.finalize_single_chapter_content=function(_,_,_,_,xhtml)
    local file=assert(io.open(home..'/fallback','wb'));assert(file:write('1'));assert(file:close())
    return xhtml,{}
end
local manager=require('ui/uimanager')
local background=require('weread.lib.background_worker'):new{temp_dir=home..'/workers',min_available_kb=1,cancel_grace=10}
assert(background:available())
local downloader=require('weread.lib.downloader'):new{settings=settings,client=client,background_worker=background,
    is_connected=function() return true end,refresh_shelf=function() end}
local done,success,result
local widget=require('ui/widget/trapwidget'):new{ text=nil };manager:show(widget)
assert(downloader:start(book,{chapter},'chapter',{prefetch=true,single_chapter=true,silent_completion=true,
    start_delay=0.1,on_complete=function(ok,value) done=true;success=ok;result=value end}))
if input.cancel then
    local function cancel_after_request()
        if not lfs.attributes(home..'/slow-request') then manager:scheduleIn(0.05,cancel_after_request);return end
        assert(downloader:cancelPrefetch('cancelled'))
    end
    manager:scheduleIn(0.05,cancel_after_request)
end
local socket=require('socket');local deadline=socket.gettime()+60
manager:setInputTimeout(0)
while not done do
    manager:handleInput()
    assert(socket.gettime()<deadline,'prefetch timed out')
    require('ffi/util').usleep(10000)
end
manager:close(widget)
local marker=io.open(home..'/fallback','rb');local fallback=marker and 1 or 0
if marker then marker:close() end
if input.cancel then
    assert(not success and result=='cancelled' and not book.cached_chapters and fallback==0)
    for name in lfs.dir(settings.cache_dir..'/42') do assert(name=='.' or name=='..','cancelled workspace remained') end
elseif input.expired then
    assert(not success and result=='native_auth_expired' and not book.cached_chapters and fallback==0)
elseif input.rejected then
    assert(not success and result=='native_resource_failed' and not book.cached_chapters and fallback==0)
else
    assert(success and type(result)=='string' and book.cached_chapters[uid]==result)
    assert(fallback==(input.mismatch and 1 or 0))
    client.request=function() error('offline request forbidden') end
    require('socket.http').request=function() error('offline request forbidden') end
    local doc=assert(require('document/documentregistry'):openDocument(result))
    assert(doc:loadDocument());doc:setFontFace('Noto Sans');doc:setFontSize(Device.screen:scaleBySize(24));doc:render()
    local proof=assert(Position.read_document(doc,book_id,uid))
    assert(proof.raw==body..(input.mismatch and '<!-- different -->' or ''))
    if input.zero_css then
        local css=assert(doc:getDocumentFileContent('OEBPS/style.css'))
        assert(not css:match('html,body%s*%{[^}]*font%-size') and css:find('.hidden{font-size:0}',1,true))
    end
    if input.multi_css then
        local css=assert(doc:getDocumentFileContent('OEBPS/style.css'))
        local first=assert(css:find('p{color:blue}',1,true))
        local second=assert(css:find('p{color:black}',1,true))
        assert(first<second,'native stylesheet order changed')
    end
    local hits=assert(doc:findAllText(owner and assert(input.search_token) or 'Native source integrated marker 24',false,0,4,false,0));assert(hits[1])
    if not input.mismatch then
        local rendered=assert(doc:getDocumentFileContent(proof.render_path))
        local name=assert(rendered:match('images/(eink%-%x+%.[a-z]+)'))
        local image=assert(doc:getDocumentFileContent('OEBPS/images/'..name))
        local bitmap=assert(require('ui/renderimage'):renderImageData(image,#image,false,160,160))
        assert(bitmap:getWidth()>0 and bitmap:getHeight()>0);bitmap:free()
        if not owner then
            local map=assert(require('weread.lib.source_coordinates').build(proof.raw))
            local position=assert(map:locate('Native source integrated marker 24'))
            local dom=assert(require('weread.lib.source_dom').open(doc,book_id,uid))
            assert(assert(dom:capture(assert(dom:locate(position.co)).xpointer)).co==position.co)
        end
    end
    doc:close()
end
print('WEREAD_PREFETCH_RESULT='..json.encode{ok=true,fallback=fallback,expired=input.expired==true,
    cancel=input.cancel==true,rejected=input.rejected==true})

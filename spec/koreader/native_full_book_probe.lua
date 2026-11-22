-- Actual resumable full-book downloader against a local synthetic source.
require('jit').off()
require('ffi').log=function() end
require('setupkoenv')
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local logger={info=function() end,warn=function() end,err=function() end,dbg=function() end}
logger.scoped=function() return logger end
package.loaded['weread.lib.logger']=logger
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local owner=input.owner==true
assert(owner and os.getenv('WEREAD_OWNER_NATIVE_FULL_TMPFS')=='1' or
    not owner and os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local scope={vid=input.credentials.vid,epoch=1}
local book_id=owner and assert(input.book_id) or '42'
local book={book_id=book_id,bookVersion=owner and input.book_version or 1,title='Full test book',author='Fixture'}
local chapters=owner and assert(input.chapters) or {{chapterUid='37',chapterIdx=1,title='First'},
    {chapterUid='38',chapterIdx=2,title='Second'},{chapterUid='39',chapterIdx=3,title='Third'}}
if input.web_asset then chapters[3].tar='https://weread.qq.com/synthetic/resources.tar' end
local values={cache={download_book_images=true,native_full_book_resources=true},books={[book_id]=book}}
local settings={mock_endpoint=not owner and input.mock_endpoint or nil,cache_dir=home..'/books',data_dir=home,
    get=function(_,key,default) return values[key] or default end,
    set=function(_,key,value) values[key]=value end,flush=function() end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_,s)
        local marker=io.open(home..'/account-switched','rb')
        if marker then marker:close();return false end
        return s==scope
    end}
local lfs=require('libs/libkoreader-lfs');assert(lfs.mkdir(settings.cache_dir))
local store={read=function() return input.credentials,1,nil,false end}
local access=require('weread.lib.native_read_access');local capture=access.capture
access.capture=function(s,existing) return capture(s,existing or store) end
local Content=require('weread.lib.content');local Position=require('weread.lib.position_source')
local cache_dir=settings.cache_dir..'/'..Content.book_dir_name(book_id);assert(lfs.mkdir(cache_dir))
local old_path=Content.book_epub_path(settings,book,'full')
local old=assert(io.open(old_path,'wb'));assert(old:write('previous full book'));assert(old:close())
book.cached_full_book=old_path
local orphan_name
if not owner then
    local orphan='\137PNG\r\n\26\nstale unrelated native image'
    orphan_name='eink-'..require('weread.lib.crypto').sha256_hex(orphan)..'.png'
    local workspace=Content.open_full_download_workspace(settings,book)
    local file=assert(io.open(workspace.asset_dir..'/'..orphan_name,'wb'))
    assert(file:write(orphan));assert(file:close())
end
local function body(uid)
    if owner then
        for _,chapter in ipairs(chapters) do if chapter.chapterUid==uid then return chapter.source end end
        error('missing owner source')
    end
    local image=uid~='39' and '<img src="https://img.qq.com/image.png?a=1&amp;b=2"/>' or ''
    return '<html><body>'..image..'<p>Full chapter '..uid..' native marker readable text.</p></body></html>'
end
Content.ensure_reader_state=function() end
local real_finalize=Content.finalize_single_chapter_content
local function web_body(uid)
    local raw=body(uid)
    if input.web_asset and uid=='39' then raw=raw:gsub('</body>','<img src="fixture.png"/></body>',1) end
    return raw..(not owner and uid=='39' and '<!-- different -->' or '')
end
Content.fetch_single_chapter_source=function(_,_,b,chapter,state)
    state.css=state.css or 'p{color:green}'
    local raw=web_body(tostring(chapter.chapterUid))
    return raw,assert(Position.capture(b,chapter,raw,'web_xhtml'))
end
Content.finalize_single_chapter_content=function(client,settings_value,book_value,chapter,xhtml,state)
    assert(not owner and chapter.chapterUid=='39')
    if input.web_asset then return real_finalize(client,settings_value,book_value,chapter,xhtml,state) end
    return xhtml,{}
end
if input.web_corrupt then
    local save=Content.save_full_download_chapter
    Content.save_full_download_chapter=function(workspace,chapter,...)
        local result=save(workspace,chapter,...)
        if chapter.chapterUid=='39' and not lfs.attributes(home..'/resume') then
            error('download_read/rate_limited',0)
        end
        return result
    end
end
if input.switch then
    local save=Content.save_book_epub
    Content.save_book_epub=function(...)
        local marker=assert(io.open(home..'/account-switched','wb'));assert(marker:write('1'));assert(marker:close())
        return save(...)
    end
end
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
local manager=require('ui/uimanager');local widget=require('ui/widget/trapwidget'):new{ text=nil };manager:show(widget)
local completed,result,alerts
alerts={}
local downloader=require('weread.lib.downloader'):new{settings=settings,client=client,
    require_login=function() return true end,run_online_task=function(_,callback) callback();return true end,
    show_info=function(value) alerts[#alerts+1]=value end,show_transient=function() end,
    safe_callback=function(_,callback) return callback end,refresh_shelf=function() end,refresh_ui=function() end}
local function start()
    completed=nil;result=nil
    assert(downloader:start(book,chapters,'full',{silent_completion=true,offer_read=false,
        on_complete=function(ok,value) completed=ok;result=value end}))
end
local function wait_done()
    local socket=require('socket');local deadline=socket.gettime()+100
    manager:setInputTimeout(0)
    while completed==nil do
        manager:handleInput();assert(socket.gettime()<deadline,'full book worker timed out')
        require('ffi/util').usleep(10000)
    end
end
start();wait_done()
if input.web_corrupt then
    assert(completed==false and result=='incomplete_full_book')
    local workspace=Content.open_full_download_workspace(settings,book)
    for i,chapter in ipairs(chapters) do assert(Content.full_download_chapter_exists(workspace,chapter,i,1,true)) end
    local prior=assert(io.open(old_path,'rb'));assert(prior:read('*a')=='previous full book');assert(prior:close())
    local path=workspace.asset_dir..'/fixture.png'
    local f=assert(io.open(path,'rb'));local bytes=assert(f:read('*a'));assert(f:close())
    assert(#bytes>20)
    local out=assert(io.open(path,'wb'));assert(out:write(bytes:sub(1,-2)..(bytes:sub(-1)=='x' and 'y' or 'x')));assert(out:close())
    assert(not Content.full_download_chapter_exists(workspace,chapters[3],3,1,true)
        and Content.full_download_chapter_exists(workspace,chapters[1],1,1,true)
        and Content.full_download_chapter_exists(workspace,chapters[2],2,1,true))
    local marker=assert(io.open(home..'/resume','wb'));assert(marker:write('1'));assert(marker:close())
    start();wait_done()
end
if input.switch then
    assert(completed==false and result=='account_changed')
    local prior=assert(io.open(old_path,'rb'));assert(prior:read('*a')=='previous full book');assert(prior:close())
    assert(not lfs.attributes(old_path..'.part'));assert(os.remove(home..'/account-switched'))
    local saved=Content.open_full_download_workspace(settings,book)
    for i,chapter in ipairs(chapters) do assert(Content.full_download_chapter_exists(saved,chapter,i,1)) end
    manager:close(widget)
    print('WEREAD_FULL_RESULT='..json.encode{ok=true,switched=true,chapters=3})
    return
end
if input.resume or input.expired then
    assert(completed==false and result==(input.expired and 'auth_expired' or 'rate_limited'))
    local workspace=Content.open_full_download_workspace(settings,book)
    assert(Content.full_download_chapter_exists(workspace,chapters[1],1,1)
        and not Content.full_download_chapter_exists(workspace,chapters[2],2,1))
    local prior=assert(io.open(old_path,'rb'));assert(prior:read('*a')=='previous full book');assert(prior:close())
    if input.expired then
        manager:close(widget)
        print('WEREAD_FULL_RESULT='..json.encode{ok=true,expired=true,chapters=1})
        return
    end
    local image_path
    for name in lfs.dir(workspace.asset_dir) do
        if name~=orphan_name and name:match('^eink%-%x+%.png$') then
            assert(not image_path);image_path=workspace.asset_dir..'/'..name
        end
    end
    local part=assert(io.open(assert(image_path)..'.part','wb'));assert(part:write('\137PNG\r\n\26\nstale'));assert(part:close())
    if input.corrupt then
        local corrupt=assert(io.open(assert(image_path),'wb'));assert(corrupt:write('damaged'));assert(corrupt:close())
        local style_path
        for name in lfs.dir(workspace.style_dir) do
            if name:match('^eink%-%x+%.css$') then assert(not style_path);style_path=workspace.style_dir..'/'..name end
        end
        local bad_style=assert(io.open(assert(style_path),'wb'));assert(bad_style:write('damaged'));assert(bad_style:close())
        local target=home..'/unrelated-file'
        local target_file=assert(io.open(target,'wb'));assert(target_file:write('must remain'));assert(target_file:close())
        assert(os.execute('ln '..string.format('%q',target)..' '..string.format('%q',style_path..'.part'))==0)
        assert(not Content.full_download_chapter_exists(workspace,chapters[1],1,1))
    end
    local marker=assert(io.open(home..'/resume','wb'));assert(marker:write('1'));assert(marker:close())
    start();wait_done()
end
assert(completed==true and type(result)=='string',tostring(result))
if input.corrupt then
    local target=assert(io.open(home..'/unrelated-file','rb'))
    assert(target:read('*a')=='must remain');assert(target:close())
end
assert(book.cached_full_book==result and not lfs.attributes(book.cache_dir..'/.weread-download-resume-full'))
client.request=function() error('offline network request forbidden') end
require('socket.http').request=function() error('offline network request forbidden') end
local doc=assert(require('document/documentregistry'):openDocument(result))
assert(doc:loadDocument());doc:setFontFace('Noto Sans');doc:setFontSize(Device.screen:scaleBySize(24));doc:render()
local opf=assert(doc:getDocumentFileContent('OEBPS/content.opf'))
if orphan_name then
    assert(not opf:find(orphan_name,1,true), 'orphan native image was listed')
    local orphan=doc:getDocumentFileContent('OEBPS/images/'..orphan_name)
    assert(not orphan or orphan=='', 'orphan native image was packaged')
end
if owner then
    local styles,images={},0
    for _,chapter in ipairs(chapters) do
        local uid=chapter.chapterUid
        local proof=assert(Position.read_document(doc,book_id,uid));assert(proof.raw==body(uid))
        local rendered=assert(doc:getDocumentFileContent(proof.render_path))
        local hash=assert(rendered:match('eink%-style%-(%x+)%.css'));styles[hash]=true
        assert(doc:getDocumentFileContent('OEBPS/eink-style-'..hash..'.css'))
        local hits=assert(doc:findAllText(chapter.search_token,false,0,8,false,0));assert(hits[1])
        local image=rendered:match('images/(eink%-%x+%.[a-z]+)')
        if image then
            local bytes=assert(doc:getDocumentFileContent('OEBPS/images/'..image))
            local bitmap=assert(require('ui/renderimage'):renderImageData(bytes,#bytes,false,100,100))
            assert(bitmap:getWidth()>0);bitmap:free();images=images+1
        end
    end
    local style_count=0;for hash in pairs(styles) do
        assert(opf:find('eink-style-'..hash,1,true));style_count=style_count+1
    end
    assert(images>0)
    doc:close();manager:close(widget)
    print('WEREAD_FULL_RESULT='..json.encode{ok=true,owner=true,chapters=#chapters,styles=style_count,images=images})
    return
end
local hashes={}
for i,chapter in ipairs(chapters) do
    local uid=chapter.chapterUid
    local proof=assert(Position.read_document(doc,'42',uid))
    assert(proof.raw==web_body(uid))
    local rendered=assert(doc:getDocumentFileContent(proof.render_path))
    local hits=assert(doc:findAllText('Full chapter '..uid..' native marker',false,0,8,false,0));assert(hits[1])
    local map=assert(require('weread.lib.source_coordinates').build(proof.raw))
    local position=assert(map:locate('Full chapter '..uid..' native marker'))
    local dom=assert(require('weread.lib.source_dom').open(doc,'42',uid))
    assert(assert(dom:capture(assert(dom:locate(position.co)).xpointer)).co==position.co)
    if i<3 then
        local hash=assert(rendered:match('eink%-style%-(%x+)%.css'));hashes[i]=hash
        local style=assert(doc:getDocumentFileContent('OEBPS/eink-style-'..hash..'.css'))
        assert(style:find(i==1 and 'p{color:black}' or 'p{color:gray}',1,true)
            and not style:match('html,body%s*%{[^}]*font%-size') and style:find('.wr%-fn%-ref'))
        local image=assert(rendered:match('images/(eink%-%x+%.png)'))
        local bytes=assert(doc:getDocumentFileContent('OEBPS/images/'..image))
        local bitmap=assert(require('ui/renderimage'):renderImageData(bytes,#bytes,false,100,100))
        assert(bitmap:getWidth()>0);bitmap:free()
        assert(style:find('images/'..image,1,true),'CSS image path must be relative to EPUB root')
    else
        assert(rendered:find('href="../style.css"',1,true))
        if input.web_asset then
            local name=input.web_corrupt and 'fixture-2.png' or 'fixture.png'
            local bytes=assert(doc:getDocumentFileContent('OEBPS/images/'..name))
            local bitmap=assert(require('ui/renderimage'):renderImageData(bytes,#bytes,false,100,100))
            assert(bitmap:getWidth()>0);bitmap:free()
            assert(rendered:find('../images/'..name,1,true))
            if input.web_corrupt then
                assert(not opf:find('images/fixture.png',1,true))
                local stale=doc:getDocumentFileContent('OEBPS/images/fixture.png')
                assert(not stale or stale=='','stale Web image was packaged')
            end
        end
    end
end
assert(hashes[1]~=hashes[2] and opf:find('eink-style-'..hashes[1],1,true)
    and opf:find('eink-style-'..hashes[2],1,true))
local _,image_count=opf:gsub('media%-type="image/png"','')
assert(image_count==(input.web_asset and 2 or 1))
doc:close();manager:close(widget)
print('WEREAD_FULL_RESULT='..json.encode{ok=true,resumed=input.resume==true,chapters=3,styles=2,images=1})

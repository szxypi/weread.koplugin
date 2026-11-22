-- Synthetic Web original plus real native HTTP adapter and production downloader.
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
local scope={vid=input.credentials.vid,epoch=1}
local scope_alive=true
local home=assert(os.getenv('KO_HOME'))
assert(home:match('^/dev/shm/'))
local cache={download_book_images=true,native_chapter_resources=true}
local values={cache=cache,books={}}
local settings={mock_endpoint=not owner and input.mock_endpoint or nil,cache_dir=home..'/books',data_dir=home,
    get=function(_,key,default) return values[key] or default end,
    set=function(_,key,value) values[key]=value end,flush=function() end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_,s) return scope_alive and s==scope end}
local lfs=require('libs/libkoreader-lfs');assert(lfs.mkdir(settings.cache_dir))
local store={read=function() return input.credentials,1,nil,false end}
local access=require('weread.lib.native_read_access')
local capture=access.capture
access.capture=function(s,existing) return capture(s,existing or store) end
local client=require('weread.lib.client'):new(settings)
local body=input.web
if not owner then
    body='<html><body><img src="https://img.qq.com/image.png?a=1&amp;b=2"/>'
    for i=1,80 do body=body..'<p>Native source integrated marker '..i..' synthetic text.</p>' end
    body=body..'</body></html>'
end
assert(type(body)=='string' and #body<=2*1024*1024)
local book_id,uid=owner and assert(input.book_id) or '42',owner and assert(input.uid) or '37'
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
local Content=require('weread.lib.content')
local Position=require('weread.lib.position_source')
Content.fetch_single_chapter_source=function(_,_,book,chapter,state)
    state.css='web-fallback';local web=body..(input.mismatch and '<!-- different -->' or '')
    return web,assert(Position.capture(book,chapter,web,'web_xhtml'))
end
Content.finalize_single_chapter_content=function(_,_,_,_,xhtml)
    local marker=assert(io.open(home..'/fallback','wb'));assert(marker:write('1'));assert(marker:close())
    return xhtml,{}
end
local book={book_id=book_id,bookVersion=owner and input.book_version or 1,title='Temporary book',author='Fixture'}
local chapter={chapterUid=uid,chapterIdx=1,title='Temporary chapter'}
local workspace=Content.create_download_workspace(settings,book)
local selected=assert(access.capture(settings))
local Identity=require('weread.lib.book_file_identity')
local job={book=book,chapters={chapter},index=1,total=1,state={workspace=workspace},workspace=workspace,
    source_identity=Identity.capture(book),native_chapter_resources=true,native_selected=selected,single_chapter=true,
    selected={},bodies={},assets={},assets_by_uid={},position_sources={},footnote_scans={},failed={},
    footnotes_done=true,silent_completion=true,started_at=0,annotation_failed_batches=0}
local Downloader=require('weread.lib.downloader')
local last_message
local downloader=Downloader:new{client=client,settings=settings,refresh_shelf=function() end,
    show_info=function(message) last_message=message end,show_transient=function() end}
local trapper=require('ui/trapper')
local manager=require('ui/uimanager')
local socket=require('socket')
local ffiutil=require('ffi/util')
job.trapper=trapper
downloader._setStage=function() end
downloader._perf=function() end
downloader._scheduleGuarded=function() end
local function step()
    local done, failure
    assert(trapper:wrap(function()
        local ok,err=pcall(downloader._step,downloader,job)
        if not ok then failure=err end
        done=true
    end))
    local deadline=socket.gettime()+60
    manager:setInputTimeout(0)
    while not done do
        manager:handleInput()
        assert(socket.gettime()<deadline,'downloader worker timed out')
        ffiutil.usleep(10000)
    end
    assert(not failure,failure)
end
if input.cancel then
    local finished,reason
    job.cancel_reason='fixture_cancel'
    job.on_complete=function(ok,value) finished=ok;reason=value end
    job.progress_dialog=require('ui/widget/trapwidget'):new{ text=nil }
    job.progress_dialog.close=function(widget) manager:close(widget) end
    manager:show(job.progress_dialog)
    local function cancel_after_request()
        if not lfs.attributes(home..'/slow-request') then
            manager:scheduleIn(0.05,cancel_after_request)
            return
        end
        job.cancelled=true
        assert(type(job.progress_dialog.dismiss_callback)=='function')
        job.progress_dialog.dismiss_callback()
    end
    manager:scheduleIn(0.05,cancel_after_request)
    step()
    assert(finished==false and reason=='fixture_cancel' and not lfs.attributes(workspace.path)
        and not next(values.books) and #job.selected==0)
    print('WEREAD_CANDIDATE_RESULT='..json.encode{ok=true,cancelled=true})
    return
end
step()
assert(job.index==2 and #job.selected==1 and #job.failed==0)
local marker=io.open(home..'/fallback','rb')
local fallback=marker and 1 or 0
if marker then marker:close() end
if input.mismatch then
    assert(fallback==1 and #job.assets==0 and job.state.css=='web-fallback')
else
    assert(fallback==0 and #job.assets>=1)
    if not owner then assert(job.state.css:find('images/eink-',1,true)) end
    assert(job.position_sources[uid])
end
local finished,path
job.on_complete=function(ok,value) finished=ok;path=value end
if input.switch then scope_alive=false end
step()
if input.switch then
    assert(finished==false and path=='account_changed' and last_message and not next(values.books))
else
    assert(finished and type(path)=='string' and values.books[book_id].cached_chapters[uid]==path,
        last_message or tostring(path))
end
if not input.mismatch and not input.switch then
    client.request=function() error('offline request forbidden') end
    require('socket.http').request=function() error('offline request forbidden') end
    local doc=assert(require('document/documentregistry'):openDocument(path))
    assert(doc:loadDocument());doc:setFontFace('Noto Sans');doc:setFontSize(Device.screen:scaleBySize(24));doc:render()
    local proof=assert(Position.read_document(doc,book_id,uid))
    assert(proof.raw==body and proof.format=='web_xhtml')
    local hits=assert(doc:findAllText(owner and assert(input.search_token) or 'Native source integrated marker 24',false,0,4,false,0))
    assert(hits[1] and hits[1].start)
    if not owner then
        local map=assert(require('weread.lib.source_coordinates').build(proof.raw))
        local position=assert(map:locate('Native source integrated marker 24'))
        local dom=assert(require('weread.lib.source_dom').open(doc,book_id,uid))
        local point=assert(dom:locate(position.co))
        assert(assert(dom:capture(point.xpointer)).co==position.co)
    end
    local image=assert(doc:getDocumentFileContent('OEBPS/'..job.assets[1].href))
    local bitmap=assert(require('ui/renderimage'):renderImageData(image,#image,false,160,160))
    assert(bitmap:getWidth()>0 and bitmap:getHeight()>0);bitmap:free();doc:close()
end
assert(not lfs.attributes(workspace.path))
print('WEREAD_CANDIDATE_RESULT='..json.encode{ok=true,fallback=fallback,assets=#job.assets,stopped=input.switch==true})

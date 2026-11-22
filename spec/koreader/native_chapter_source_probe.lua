-- Real credentials, identity and text enter only via a private pipe.
require('jit').off()
require('ffi').log=function() end
require('setupkoenv')
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
package.loaded['weread.lib.logger']={info=function() end,warn=function() end,err=function() end,dbg=function() end}
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local count,reason=0,'probe_failed'
local ok,result=pcall(function()
    local raw=assert(io.stdin:read(65537));assert(#raw<=65536)
    local input=json.decode(raw)
    local scope={vid=input.credentials.vid,epoch=1}
    local settings={get=function(_self,_key,default) return default end,
        get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
    if input.mock_endpoint~=nil then
        assert(os.getenv('WEREAD_SYNTHETIC')=='1' and type(input.mock_endpoint)=='string'
            and input.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
        settings.mock_endpoint=input.mock_endpoint
    end
    local store={read=function() return input.credentials,1,nil,false end}
    local client=require('weread.lib.client'):new(settings)
    local request=client.request
    client.request=function(self,options)
        count=count+1
        assert(count<=67 and options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
        local base='https://i.weread.qq.com'
        if count==1 then
            assert(options.url==base..'/book/info?bookId='..input.book_id and options.method=='GET')
        elseif count==2 then
            assert(options.url==base..'/book/chapterInfos' and options.method=='POST')
            local body=json.decode(options.body)
            assert(body.bookIds[1]==input.book_id and #body.bookIds==1 and body.synckeys[1]==0)
        elseif count==3 then
            assert(options.method=='GET' and options.url:find(base..'/book/chapterdownload?',1,true)==1
                and options.url:find('stopAutoPayWhenBNE=1',1,true) and options.url:find('preview=0',1,true))
        else
            assert(input.fetch_remote==true and options.method=='GET'
                and require('weread.lib.native_chapter_remote').allowed(options.url)==options.url
                and not options.headers.vid and not options.headers.accessToken and not options.headers.Cookie)
        end
        return request(self,options)
    end
    local selected=assert(require('weread.lib.native_read_access').capture(settings,store))
    local source,why=require('weread.lib.native_chapter_source').fetch(client,settings,selected,input.book_id,input.uid,
        {is_current=function() return true end})
    if not source then reason=why;error('source_failed') end
    assert(count==3 and source.source_channel=='eink' and source.coordinate_source_authoritative==false)
    local Crypto=require('weread.lib.crypto')
    local assets=json.decode('[]')
    for _,asset in ipairs(source.assets) do
        assets[#assets+1]={digest=Crypto.sha256_hex(asset.data),mime=asset.media_type,
            safe_href=asset.href:match('^images/native%-%d+%.[a-z]+$')~=nil,
            parent_source=asset.source:find('../',1,true)~=nil}
    end
    local output={ok=true,requests=count,body_sha256=Crypto.sha256_hex(source.body),css_sha256=Crypto.sha256_hex(source.css),
        is_text=source.is_text,web_coordinate_authority=source.coordinate_source_authoritative,assets=assets,
        image_signatures_recognized=source.image_signatures_recognized,unusable_resources=source.unusable_resources}
    if input.prepare==true then
        local prepared,resource_reason=require('weread.lib.native_chapter_resources').prepare(source)
        if prepared and input.fetch_remote==true then
            prepared,resource_reason=require('weread.lib.native_chapter_remote').complete(client,source,
                {is_current=function() return require('weread.lib.native_read_access').matches(settings,selected) end})
            if not prepared then reason=resource_reason;error('remote_failed') end
        end
        if prepared then
            output.resources={ok=true,localized=prepared.localized_references,remote=prepared.remote_references,
                web_coordinate_authority=prepared.coordinate_source_authoritative}
            if input.fetch_remote==true then output.resources.downloaded=prepared.downloaded_images end
            if input.audit_remote==true then output.resources.downloaded_digests=prepared.downloaded_digests end
            if input.render==true or input.owner_render==true then
                local home=assert(os.getenv('KO_HOME'))
                local owner=input.owner_render==true
                assert(home:match('^/dev/shm/') and prepared.remote_references==0)
                if owner then
                    assert(os.getenv('WEREAD_OWNER_NATIVE_IMAGE_TMPFS')=='1' and type(input.search_token)=='string'
                        and #input.search_token>=6 and #input.search_token<=128)
                else assert(os.getenv('WEREAD_SYNTHETIC')=='1') end
                local lfs=require('libs/libkoreader-lfs');settings.cache_dir=home..'/native-cache'
                if not lfs.attributes(settings.cache_dir) then assert(lfs.mkdir(settings.cache_dir)) end
                local book={book_id=input.book_id,bookVersion=source.book_version,title='Synthetic native book',author='Fixture'}
                local chapter={chapterUid=tonumber(input.uid),chapterIdx=1,title='Synthetic chapter'}
                local path=require('weread.lib.content').save_chapter_epub(settings,book,chapter,prepared.xhtml,prepared.assets,
                    prepared.css,require('weread.lib.book_file_identity').capture(book),nil)
                client.request=function() error('offline request forbidden') end
                require('socket.http').request=function() error('offline request forbidden') end
                local Device=require('device');require('document/canvascontext'):init(Device)
                local doc=assert(require('document/documentregistry'):openDocument(path))
                assert(doc:loadDocument());doc:setFontFace('Noto Sans');doc:setFontSize(Device.screen:scaleBySize(24));doc:render()
                local hits=assert(doc:findAllText(owner and input.search_token or 'Native source integrated marker 24',false,0,4,false,0))
                assert(doc:getPageCount()>=(owner and 1 or 2) and hits[1] and hits[1].start)
                assert(not require('weread.lib.position_source').read_document(doc,input.book_id,input.uid))
                assert(#prepared.assets>0)
                local saved_assets=json.decode('[]')
                for _,asset in ipairs(prepared.assets) do
                    assert(doc:getDocumentFileContent('OEBPS/'..asset.href)==asset.data)
                    local bitmap=assert(require('ui/renderimage'):renderImageData(asset.data,#asset.data,false,160,160))
                    assert(bitmap:getWidth()>0 and bitmap:getHeight()>0);bitmap:free()
                    saved_assets[#saved_assets+1]={href=asset.href,digest=Crypto.sha256_hex(asset.data)}
                end
                if not owner then assert(assert(doc:getDocumentFileContent('OEBPS/style.css')):find(prepared.assets[1].href,1,true)) end
                doc:close()
                if owner then
                    local state=assert(io.open(home..'/native-owner-state.json','wb'))
                    assert(state:write(json.encode{path=path,book_id=input.book_id,uid=input.uid,assets=saved_assets}))
                    assert(state:close());output.resources.owner_rendered=true
                else output.resources.rendered=true end
            end
        else
            output.resources={ok=false,reason=resource_reason}
        end
    end
    output.requests=count
    return output
end)
if reason~='invalid' and reason~='session_changed' and reason~='rate_limited' and reason~='auth_expired' and reason~='service_rejected'
    and reason~='not_entitled' and reason~='unavailable' and reason~='invalid_image' and reason~='remote_unsupported'
    and reason~='source_changed' and reason~='invalid_source' then reason='probe_failed' end
io.stdout:write('\nWEREAD_NATIVE_SOURCE_RESULT='..json.encode(ok and result or {ok=false,requests=count,reason=reason})..'\n')
os.exit(ok and 0 or 1)

-- Synthetic native chapters with verified catalog order and neighbors.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));local scope={vid=input.credentials.vid,epoch=1}
local data_dir=input.plugin_profile and home..'/weread' or home
if input.plugin_profile then assert(require('libs/libkoreader-lfs').mkdir(data_dir)) end
local settings={data_dir=data_dir,cache_dir=data_dir,mock_endpoint=input.mock_endpoint,
    get=function(_,key,default) if key=='account' then return {user_vid=scope.vid} end return default end,
    get_auth_scope=function() return scope end,
    auth_scope_matches=function(_,value) return value==scope end}
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local original=Access.capture
Access.capture=function(s,existing) return original(s,existing or store) end
local selected=assert(Access.capture(settings));local client=require('weread.lib.client'):new(settings);local request=client.request
client.request=function(self,options)
    local url,headers=options.url,options.headers or {}
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    assert((url=='https://i.weread.qq.com/book/info?bookId=42' and options.method=='GET')
        or (url=='https://i.weread.qq.com/book/chapterInfos' and options.method=='POST')
        or (url:find('https://i.weread.qq.com/book/chapterdownload?',1,true)==1 and options.method=='GET')
        or (require('weread.lib.native_chapter_remote').allowed(url)==url and options.method=='GET'
            and not headers.vid and not headers.accessToken and not headers.Cookie))
    return request(self,options)
end
local auth=require('weread.lib.native_authorization'):new(client,{expected_vid=scope.vid,
    is_current=function() return Access.matches(settings,selected) end})
local catalog=require('weread.lib.native_book_catalog').read(auth,input.credentials,'42','native_catalog');auth:cancel()
local rows=assert(catalog.reading_chapters);assert(#rows==3)
local output={}
for _,index in ipairs((input.mode=='two' or input.mode=='full' or input.mode=='copies') and {1,2} or input.mode=='gap' and {1,3} or {1}) do
    local row=rows[index];row.catalog_order=index;row.catalog_count=#rows
    row.catalog_prev=rows[index-1] and rows[index-1].chapterUid or nil
    row.catalog_next=rows[index+1] and rows[index+1].chapterUid or nil
    local expected={book_id='42',chapter_uid=row.chapterUid,book_version=catalog.version,
        reading_catalog_sha256=catalog.reading_digest,access_fingerprint=selected.fingerprint}
    local saved=assert(require('weread.lib.native_direct_reader').build(client,settings,
        {book_id='42',title='Synthetic',author='Fixture'},row,expected,{is_current=function() return true end}))
    output[row.chapterUid]=saved.path
    if (input.mode=='copies' and index==2) or (input.mode=='online' and index==1) then
        local prepared=assert(require('weread.lib.native_direct_source').fetch(client,settings,'42',row.chapterUid,expected,
            {is_current=function() return true end,allow_missing_images=true}))
        prepared.xhtml=prepared.xhtml:gsub('</body>','<p>One synthetic image is missing.</p></body>',1)
        prepared.missing_images=1
        local missing=assert(require('weread.lib.native_direct_cache').publish(settings,scope.vid,
            {book_id='42',title='Synthetic',author='Fixture'},row,prepared,function() return true end))
        assert(missing.path~=saved.path);output.missing_copy=missing.path
    end
end
if input.plugin_profile then
    local library=require('weread.lib.library_db'):new(settings)
    local compact=assert(require('weread.ui.native_direct_reading').project(catalog,'42'))
    assert(require('weread.lib.native_direct_catalog_store').save(library,settings,client,scope,compact,function() return true end),
        'synthetic catalog estimate was not saved')
end
print('WEREAD_DIRECT_NAV_PREPARED='..json.encode(output))

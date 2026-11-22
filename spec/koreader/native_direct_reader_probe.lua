-- Synthetic native-only source to isolated EPUB; no Web request is permitted.
require('jit').off()
require('ffi').log=function() end
require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local scope={vid=input.credentials.vid,epoch=1};local alive=true
local settings={data_dir=home,cache_dir=home,mock_endpoint=input.mock_endpoint,
    get=function(_,_,default) return default end,get_auth_scope=function() return scope end,
    auth_scope_matches=function(_,value) return alive and value==scope end}
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local capture=Access.capture
Access.capture=function(s,existing) return capture(s,existing or store) end
local selected=assert(Access.capture(settings))
local Catalog=require('weread.lib.native_book_catalog')
local catalog=Catalog.project({data={{bookId='42',updated={{chapterUid=37,wordCount=250,price=0}}}}},
    '42',{bookId='42',format='epub',version=1})
local expected={book_id='42',chapter_uid='37',book_version=1,reading_catalog_sha256=catalog.reading_digest,
    access_fingerprint=selected.fingerprint}
local client=require('weread.lib.client'):new(settings);local request=client.request;local requests=0
client.request=function(self,options)
    requests=requests+1
    local url=options.url
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    assert((url=='https://i.weread.qq.com/book/info?bookId=42' and options.method=='GET')
        or (url=='https://i.weread.qq.com/book/chapterInfos' and options.method=='POST')
        or (url:find('https://i.weread.qq.com/book/chapterdownload?',1,true)==1 and options.method=='GET')
        or (require('weread.lib.native_chapter_remote').allowed(url)==url and options.method=='GET'
            and not options.headers.vid and not options.headers.accessToken and not options.headers.Cookie))
    local a,b,c=request(self,options)
    if input.switch and requests==1 then alive=false end
    return a,b,c
end
local book={book_id='42',title='Synthetic native book',author='Fixture'}
local chapter={chapterUid='37',title='Synthetic chapter',chapterIdx=1}
local Reader=require('weread.lib.native_direct_reader')
local function build(value) return Reader.build(client,settings,book,chapter,value or expected,
    {is_current=function() return true end,allow_missing_images=input.missing==true}) end
if input.switch_commit then
    local content=require('weread.lib.content');local save=content.save_chapter_epub
    content.save_chapter_epub=function(...) alive=false;return save(...) end
    local result,reason=build()
    assert(not result and reason=='session_changed' and requests==4)
    local lfs=require('libs/libkoreader-lfs')
    local function audit(dir)
        for name in lfs.dir(dir) do if name~='.' and name~='..' then
            local path=dir..'/'..name;local attr=assert(lfs.symlinkattributes(path))
            if attr.mode=='directory' then audit(path)
            else assert(not name:match('%.epub$') and not name:match('%.part$') and name~='receipt.txt') end
        end end
    end
    audit(home..'/native-reader-v1')
    print('WEREAD_DIRECT_RESULT='..json.encode{ok=true,switched_before_commit=true,requests=requests})
    return
end
if input.switch then
    local result,reason=build()
    assert(not result and reason=='session_changed' and requests==1)
    print('WEREAD_DIRECT_RESULT='..json.encode{ok=true,switched=true,requests=requests})
    return
end
local first=assert(build());assert(not first.reused and first.path:find('/native%-reader%-v1/')
    and first.missing_images==(input.missing and 1 or 0))
local lfs=require('libs/libkoreader-lfs');local before=assert(lfs.attributes(first.path))
local second=assert(build());assert(second.reused and second.path==first.path)
local after=assert(lfs.attributes(first.path));assert(before.ino==after.ino and before.size==after.size)
local receipt=assert(io.open(first.path:match('^(.*)/[^/]+$')..'/receipt.txt','wb'))
assert(receipt:write('invalid receipt'));assert(receipt:close())
local third=assert(build());assert(not third.reused and third.path~=first.path)
assert(assert(lfs.attributes(first.path)).size==before.size,'receipt failure replaced the prior file')
local altered=assert(io.open(third.path,'ab'));assert(altered:write('corrupt'));assert(altered:close())
local damaged=assert(lfs.attributes(third.path)).size
local fourth=assert(build());assert(not fourth.reused and fourth.path~=third.path)
assert(assert(lfs.attributes(third.path)).size==damaged,'damaged prior file was replaced')
local stale={};for key,value in pairs(expected) do stale[key]=value end
stale.reading_catalog_sha256=string.rep('d',64)
local result,reason=build(stale);assert(not result and reason=='catalog_changed')
assert(requests==19)
print('WEREAD_DIRECT_RESULT='..json.encode{ok=true,requests=requests,reused=true,corrupt_preserved=true,
    receipt_preserved=true,missing_images=fourth.missing_images,path=fourth.path})

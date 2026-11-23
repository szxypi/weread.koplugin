package.path='./?.lua;'..package.path
local stored,requests,alive,preserve,race,fail=nil,0,true,nil,false,false
package.preload['mime']=function() return {b64=function(value) return 'encoded:'..#value end} end
package.preload['weread.lib.thought_image_store']=function() return {
    key=function(book,review,url) assert(book=='42' and review=='review' and url:find('myqcloud',1,true));return 'key' end,
    new=function() return {read=function() return stored end,write=function(_,owner,key,data,options)
        assert(owner=='owner' and key=='key');preserve=options.preserve_existing
        if fail then return false end
        if race then stored=data..'x';return 'exists' end
        stored=data;return true end} end} end
local Image=require('weread.lib.thought_image')
local png='\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\10\0\0\0\20'..string.rep('\0',10)
local url='https://weread-picture-1258476243.file.myqcloud.com/synthetic.png'
local library={accountKey=function() return 'owner' end}
local client={request=function(_,options)
    requests=requests+1;assert(options.url==url and options.method=='GET' and options.skip_cookie and options.sensitive
        and options.persist_response_cookies==false and not options.headers.Cookie and not options.headers.Authorization)
    assert(options.sink(png));options.sink(nil);return nil,200
end}
local function load(online) return Image.load(client,library,'owner','42','review',url,online,function() return alive end) end
local value,why=load(false);assert(not value and why=='offline' and requests==0)
value=assert(load(true));assert(value.bytes=='encoded:'..#png and stored==png and requests==1)
value=assert(load(false));assert(value.bytes=='encoded:'..#png and requests==1)
assert(Image.prefetch(client,library,'owner','42','review',url,function() return alive end)=='cached' and requests==1)
stored=nil;assert(Image.prefetch(client,library,'owner','42','review',url,function() return alive end)=='saved'
    and preserve and requests==2)
stored=nil;race=true;assert(Image.prefetch(client,library,'owner','42','review',url,function() return alive end)=='cached'
    and stored==png..'x' and requests==3)
stored=nil;race=false;fail=true
local status,reason=Image.prefetch(client,library,'owner','42','review',url,function() return alive end)
assert(not status and reason=='storage' and not stored and requests==4)
stored=png;fail=false;alive=false;assert(not load(true) and requests==4)
alive=true;library.accountKey=function() return nil end
value=assert(Image.load(client,library,nil,'42','review',url,true,function() return alive end))
assert(value.bytes=='encoded:'..#png and requests==5 and stored==png,'key-only download should not use account storage')
value,why=Image.load(client,library,nil,'42','review',url,false,function() return alive end)
assert(not value and why=='offline' and requests==5)
print('PASS: thought image scoped anonymous fetch and offline cache')

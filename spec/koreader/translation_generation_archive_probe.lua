-- Real EPUB archive and source binding, with synthetic data and no network.
require('setupkoenv')
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(os.getenv('WEREAD_TEST_DIR'))
local Content=require('weread.lib.content')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Archive=require('weread.lib.source_archive')
local Crypto=require('weread.lib.crypto')
local raw='<html><body><p>'..string.rep('This is a synthetic readable paragraph. ',8)..'</p></body></html>'
local book={book_id='456',bookVersion=7,title='Synthetic',author='Test',cache_dir=root}
local chapter={chapterUid=7,title='Chapter One',wordCount=1200}
local settings={cache_dir=root,get=function(_self,_key,default) return default end}
local source=assert(Source.capture(book,chapter,raw,'web_xhtml'))
local path=assert(Content.save_chapter_epub(settings,book,chapter,raw,nil,nil,Identity.capture(book),source))
local function bytes() local f=assert(io.open(path,'rb'));local v=assert(f:read('*a'));f:close();return v end
local original=bytes()
local head=assert(Archive.read(path,{[Identity.PATH]=Identity.MAX_BYTES,[Source.meta_path('7')]=Source.MAX_META_BYTES}))
local identity=assert(Identity.decode(head[Identity.PATH]))
local metadata=assert(head[Source.meta_path('7')])
local input={book_id='456',chapter_uid='7',path=path,metadata=metadata,file_id=identity.file_id}
local calls,remote=0,raw
Content.ensure_reader_state=function() end
Content.fetch_catalog=function() return {{chapterUid=7,title='Chapter One'}},7 end
Content.fetch_chapter_xhtml=function()
    calls=calls+1
    return remote,assert(Source.capture(book,chapter,remote,'web_xhtml'))
end
require('weread.lib.translation_fetch').client=function(client) return client end
require('weread.lib.native_read_access').matches=function() return true end
require('weread.lib.translation_generation_access').inspect=function()
    return {book_id='456',uid=7,version=7,catalog_sha256=string.rep('a',64),translate_version=0,title='Chapter One'}
end
local inspect=require('weread.lib.translation_generation_source').inspect
local client={request=function() error('unexpected network request') end}
local options={is_current=function() return true end}
local result,reason=inspect(client,settings,{},input,options)
assert(result and result.kind=='source_verified' and result.source_sha256==Crypto.sha256_hex(raw) and calls==2,reason)
remote=raw:gsub('</p>', '</p><p class="wr-translation">测试译文</p>')
result,reason=inspect(client,settings,{},input,options)
assert(result and result.kind=='available',reason)
remote=raw..'changed'
result,reason=inspect(client,settings,{},input,options)
assert(not result and reason=='source_changed','changed original was accepted')
input.metadata='wrong';result,reason=inspect(client,settings,{},input,options)
assert(not result and reason=='local_source','changed metadata was accepted')
assert(bytes()==original,'source archive was modified')
print('PASS: actual EPUB archive, repeated source, existing translation, and mismatch rejection')

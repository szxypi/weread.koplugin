-- Build a deliberately incomplete comparison copy from an already verified
-- chapter. It stays in the disposable profile and never accesses the network.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
assert(dofile(assert(arg[2])..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local data=input.plugin_home and home..'/weread' or home
local settings={data_dir=data,cache_dir=data,get=function(_,_,default) return default end}
local Cache=require('weread.lib.native_direct_cache')
local live=function() return true end
local entry=assert(Cache.identify(settings,input.vid,input.path,live))
assert(entry.catalog_sha256 and entry.catalog_order and entry.catalog_count and entry.missing_images==0)
local document=assert(require('document/documentregistry'):openDocument(input.path))
assert(document:loadDocument())
local xhtml=assert(document:getDocumentFileContent('OEBPS/text/chapter.xhtml'))
document:close()
local image=require('weread.lib.native_missing_image')
local href='images/eink-'..require('weread.lib.crypto').sha256_hex(image)..'.png'
local warning=require('weread.lib.plugin_util').tr('Some images could not be loaded; placeholders are shown.')
local banner='<p>'..warning..'</p><img src="../'..href..'"/>'
local count
xhtml,count=xhtml:gsub('</body>',banner..'</body>',1);assert(count==1)
local book={book_id=entry.book_id,title='Synthetic native book',author='Fixture'}
local chapter={chapterUid=entry.chapter_uid,title=entry.title,chapterIdx=entry.chapter_idx,
    catalog_order=entry.catalog_order,catalog_count=entry.catalog_count,catalog_prev=entry.catalog_prev,catalog_next=entry.catalog_next}
local prepared={book_id=entry.book_id,chapter_uid=entry.chapter_uid,book_version=entry.book_version,
    catalog_sha256=entry.catalog_sha256,reading_catalog_sha256=entry.catalog_sha256,source_sha256=entry.source_sha256,
    source_channel='eink',coordinate_source_authoritative=false,missing_images=1,xhtml=xhtml,css='',
    assets={{href=href,data=image,media_type='image/png'}}}
local missing=assert(Cache.publish(settings,input.vid,book,chapter,prepared,live))
assert(missing.path~=input.path and missing.missing_images==1)
print('WEREAD_DIRECT_OWNER_MISSING_COPY='..json.encode{ok=true,path=missing.path})

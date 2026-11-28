-- Real Linux file-size failure through KOReader's content extractor.
require('jit').off()
require('ffi').log=function() end
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local ffi=require('ffi')
ffi.cdef[[
struct wr_resource_limit { unsigned long current; unsigned long maximum; };
int getrlimit(int, struct wr_resource_limit *);
int setrlimit(int, const struct wr_resource_limit *);
void (*signal(int, void (*)(int)))(int);
]]
assert(ffi.os=='Linux' and os.getenv('WEREAD_SYNTHETIC')=='1')
ffi.C.signal(25,ffi.cast('void (*)(int)',1)) -- SIGXFSZ / SIG_IGN
local original=ffi.new('struct wr_resource_limit[1]')
assert(ffi.C.getrlimit(1,original)==0) -- RLIMIT_FSIZE
local limited=ffi.new('struct wr_resource_limit[1]')
limited[0].current=1024;limited[0].maximum=original[0].maximum
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local lfs=require('libs/libkoreader-lfs')
local workspace={path=home..'/work',incoming_dir=home..'/work/incoming',asset_dir=home..'/work/images'}
assert(lfs.mkdir(workspace.path));assert(lfs.mkdir(workspace.incoming_dir));assert(lfs.mkdir(workspace.asset_dir))
local function write(path,data)
    local f=assert(io.open(path,'wb'));assert(f:write(data));assert(f:close())
end
local function read(path)
    local f=assert(io.open(path,'rb'));local data=assert(f:read('*a'));assert(f:close());return data
end
local preserved=home..'/preserved'
write(preserved,'must not be truncated')
assert(lfs.link(preserved,workspace.incoming_dir..'/resource-image.part'))
write(workspace.asset_dir..'/other.jpg','other image')
local function tar_header(name,size)
    local header=name..string.rep('\0',100-#name)..string.rep('0',24)
        ..string.format('%011o\0',size)..string.rep('0',20)..'0'
    return header..string.rep('\0',512-#header)
end
local image='\255\216\255'..string.rep('x',4093)
local zip_input=home..'/zip-picture.jpg'
local zip_path=home..'/fixture.zip'
write(zip_input,image)
assert(os.execute('zip -jq '..string.format('%q',zip_path)..' '..string.format('%q',zip_input))==0)
local zip_data=read(zip_path)
local limit_next=true
local using_zip=false
local client={}
function client:download_to_file(_,path)
    write(path,using_zip and zip_data or tar_header('picture.jpg',#image)..image..string.rep('\0',1024))
    if limit_next then assert(ffi.C.setrlimit(1,limited)==0) end
    return path
end
local Content=require('weread.lib.content')
local names={}
local ok=pcall(Content.download_chapter_assets_to_files,client,{book_id='book'},
    {chapterUid=1,tar='https://example.invalid/resource'},names,workspace)
assert(ffi.C.setrlimit(1,original)==0)
assert(not ok and not lfs.attributes(workspace.asset_dir..'/picture.jpg')
    and not lfs.symlinkattributes(workspace.incoming_dir..'/resource-image.part')
    and not names['picture.jpg'] and read(preserved)=='must not be truncated'
    and read(workspace.asset_dir..'/other.jpg')=='other image')
limit_next=false
local assets=Content.download_chapter_assets_to_files(client,{book_id='book'},
    {chapterUid=1,tar='https://example.invalid/resource'},names,workspace)
assert(#assets==1 and read(assets[1].path)==image and names['picture.jpg'])
using_zip=true;limit_next=true
local zip_names={}
ok=pcall(Content.download_chapter_assets_to_files,client,{book_id='book'},
    {chapterUid=2,tar='https://example.invalid/resource'},zip_names,workspace)
assert(ffi.C.setrlimit(1,original)==0)
assert(not ok and not lfs.attributes(workspace.asset_dir..'/zip-picture.jpg')
    and not lfs.symlinkattributes(workspace.incoming_dir..'/resource-image.part')
    and not zip_names['zip-picture.jpg'] and read(assets[1].path)==image)
limit_next=false
local zip_assets=Content.download_chapter_assets_to_files(client,{book_id='book'},
    {chapterUid=2,tar='https://example.invalid/resource'},zip_names,workspace)
assert(#zip_assets==1 and read(zip_assets[1].path)==image and zip_names['zip-picture.jpg'])
print('PASS: TAR and ZIP kernel write failures, cleanup, hardlink protection and retry')

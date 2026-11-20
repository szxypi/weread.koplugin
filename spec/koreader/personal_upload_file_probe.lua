-- Real descriptor identity and journal lock checks with synthetic files.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local ffi=require('ffi');require('ffi/posix_h')
ffi.cdef('int symlink(const char *target, const char *linkpath);')
local lfs=require('libs/libkoreader-lfs')
local root=os.tmpname();os.remove(root);assert(lfs.mkdir(root))
local path=root..'/synthetic.txt'
local function write(value) local f=assert(io.open(path,'wb'));assert(f:write(value));f:close() end
write('synthetic content')
local Model=require('weread.lib.personal_upload');local input=assert(Model.capture(path))
local file=assert(Model.open_file(input));assert(file:read(65536)=='synthetic content');assert(file:read(65536)==nil)
assert(file:seek()==0 and file:read(65536)=='synthetic content');file:close()
assert(os.rename(path,path..'.old'));assert(ffi.C.symlink(path..'.old',path)==0)
assert(not Model.open_file(input),'replacement symlink was followed')
os.remove(path);os.remove(path..'.old')
local json=require('json');local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local scope={vid='900000',epoch=1};local settings={data_dir=root,auth_scope_matches=function(_self,value) return value and value.vid==scope.vid and value.epoch==scope.epoch end}
local Journal=require('weread.lib.personal_upload_journal');local journal=Journal:new(settings,codec)
local gate=assert(require('weread.lib.file_lease').open(journal:path(scope)..'.lock',{create=true,empty=true}))
assert(not journal:begin(scope,'/synthetic/file.txt',8),'parallel intent bypassed the lease');gate:release()
local record=assert(journal:begin(scope,'/synthetic/file.txt',8));assert(journal:owns(scope,record))
assert(not journal:begin(scope,'/synthetic/other.txt',8),'pending intent was replaced')
assert(journal:finish(scope,record) and journal:read(scope).phase=='idle')
os.remove(journal:path(scope));os.remove(journal:path(scope)..'.lock');assert(lfs.rmdir(root))
print('PASS: native upload descriptor and exclusive intent')

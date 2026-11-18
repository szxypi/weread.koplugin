-- Standalone native-runtime probe; all book data and network state are synthetic.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local ffi=require('ffi');require('ffi/posix_h')
local Identity=require('weread.lib.book_file_identity')
local Source=require('weread.lib.position_source')
local Crypto=require('weread.lib.crypto')
local Worker=require('weread.lib.memory_worker')
local socket=require('socket')
local json=require('json')
local count=assert(tonumber(arg[2]));assert(count>=2 and count<=10000 and count%1==0)
local chapters={}
for i=1,count do chapters[i]={chapterUid=tostring(i),chapterIdx=i-1,wordCount=100} end
local book={bookId='CB_Synthetic',bookVersion=0}
local root=Identity.encode(book,chapters,Identity.capture(book),Crypto.sha256_hex('synthetic bundle'),0)
local identity=assert(Identity.decode(root));local path=os.tmpname()
local fd=ffi.C.open(path,ffi.C.O_WRONLY+ffi.C.O_TRUNC);assert(fd>=0)
local writer=require('weread.lib.epub_export_writer').new(fd)
writer:add(Identity.PATH,root,#root,false)
for i,chapter in ipairs(chapters) do
    local raw='Synthetic benchmark chapter '..i
    local name=string.format('OEBPS/text/chapter-%03d.xhtml',i)
    local capture=assert(Source.capture(book,chapter,raw,'web_txt'))
    local meta=assert(Source.bind(capture,identity,name,Crypto.sha256_hex(raw)))
    writer:add(Source.raw_path(capture.raw_sha256),raw,#raw,false)
    writer:add(Source.meta_path(chapter.chapterUid),meta,#meta,false)
    writer:add(Source.path_meta_path(name),meta,#meta,false)
    writer:add(name,raw,#raw,false)
end
assert(writer:close());assert(ffi.C.close(fd)==0)
local jobs={}
local scheduler={}
function scheduler:scheduleIn(delay,callback) jobs[callback]=socket.gettime()+delay end
function scheduler:unschedule(callback) jobs[callback]=nil end
local codec={json_encode=function(_,value) return json.encode(value) end,
    json_decode=function(_,value) return json.decode(value) end}
local worker=Worker:new{scheduler=scheduler,codec=codec,max_bytes=1024*1024}
local result,finished;local start=socket.gettime()
assert(worker:start(function()
    return require('weread.lib.readtime_source').scan_page({cached_full_book=path},chapters,
        {book_id=book.bookId,book_version=0,file_id=identity.file_id},nil,1)
end,function(value) result=value;finished=true end))
while not finished do
    assert(socket.gettime()-start<80,'source scan worker failed to finish')
    local now=socket.gettime();local ready={}
    for callback,deadline in pairs(jobs) do if deadline<=now then ready[#ready+1]=callback end end
    for _i,callback in ipairs(ready) do if jobs[callback] then jobs[callback]=nil;callback() end end
    socket.sleep(.02)
end
local elapsed=socket.gettime()-start
assert(type(result)=='table' and result.kind=='found' and #result.reference.chapters==count,'source scope was not returned')
assert(not worker.job and os.remove(path))
print(string.format('chapters=%d elapsed_seconds=%.3f worker_result=PASS',count,elapsed))

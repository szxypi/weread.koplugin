-- Private source and plans stay in captured pipes. No network or settings.
require('ffi').log=function() end
require('setupkoenv');package.path='/source/?.lua;'..package.path
local Json=require('json');local raw=assert(io.stdin:read(8*1024*1024+1));assert(#raw<=8*1024*1024)
local input=Json.decode(raw);local C=require('weread.lib.mark_edit_contract');local Point=require('weread.lib.bookmark_point')
local codec={json_encode=function(_self,v) return Json.encode(v) end,json_decode=function(_self,v) return Json.decode(v) end}
local point=assert(Point.project(input.raw,input.co));local target=assert(Point.from_mark(input.raw,input.snapshot.book_id,tostring(input.target.chapterUid),input.target))
local plans={C.make(codec,input.snapshot,'bookmark_create',input.reference,input.metadata),C.make(codec,input.deletion_snapshot,'bookmark_delete',input.target)}
io.write('\nWEREAD_BOOKMARK_CONTRACT_RESULT='..Json.encode{point=point,target=target,plans=plans}..'\n')

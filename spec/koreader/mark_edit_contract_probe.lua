-- Private inputs/outputs use captured pipes. No request or settings writes.
require('ffi').log=function() end
require('setupkoenv');package.path='/source/?.lua;'..package.path
local Json=require('json');local raw=assert(io.stdin:read(8*1024*1024+1));assert(#raw<=8*1024*1024)
local input=Json.decode(raw);local C=require('weread.lib.mark_edit_contract')
local codec={json_encode=function(_self,v) return Json.encode(v) end,json_decode=function(_self,v) return Json.decode(v) end}
local plans={C.make(codec,input.snapshot,'create',input.reference,input.metadata),C.make(codec,input.deletion_snapshot,'delete',input.target)}
if input.styles then
    for _i,style in ipairs({0,2}) do plans[#plans+1]=C.make(codec,input.deletion_snapshot,'style',input.target,nil,style) end
    local snapshot=Json.decode(Json.encode(input.deletion_snapshot));local row=snapshot.marks.updated[#snapshot.marks.updated];row.style=0
    plans[#plans+1]=C.make(codec,snapshot,'style',row,nil,1)
end
if input.initial_styles then
    for _i,style in ipairs({0,2}) do plans[#plans+1]=C.make(codec,input.snapshot,'create',input.reference,input.metadata,style) end
end
if input.colors then
    for color=0,5 do plans[#plans+1]=C.make(codec,input.snapshot,'create',input.reference,input.metadata,2,color) end
    for color=1,5 do plans[#plans+1]=C.make(codec,input.deletion_snapshot,'color',input.target,nil,nil,color) end
    local snapshot=Json.decode(Json.encode(input.deletion_snapshot));local row=snapshot.marks.updated[#snapshot.marks.updated]
    row.style,row.colorStyle=2,3;plans[#plans+1]=C.make(codec,snapshot,'color',row,nil,nil,0)
end
io.write('\nWEREAD_HIGHLIGHT_CONTRACT_RESULT='..Json.encode(plans)..'\n')

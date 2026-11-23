package.path='./?.lua;'..package.path
local F=require('weread.lib.thought_attachment_fingerprint')
local A=require('weread.lib.thought_attachments')
local null,array_mt={},{}
local function present(value) return value~=nil and value~=null end
local function array(value) return setmetatable(value or {},array_mt) end
local url='https://weread-picture-1258476243.file.myqcloud.com/synthetic.png'
local first={pictures=array({{url=url,width=100,metadata={z=2,a=1},extra=array()}}),pencilNote=null}
local reordered={pencilNote=null,pictures=array({{extra=array(),metadata={a=1,z=2},width=100,url=url}})}
local base=assert(F.compute(first,present,array_mt));assert(#base==64 and F.compute(reordered,present,array_mt)==base)
reordered.pictures[1].metadata.z=3;assert(F.compute(reordered,present,array_mt)~=base)
reordered.pictures[1].metadata.z=2;reordered.pictures[1].extra={}
assert(F.compute(reordered,present,array_mt)~=base,'empty array and object were conflated')
local result=assert(A.project(first,present,{array_mt=array_mt}))
assert(result.digest==base and result.state=='available' and result.urls==url)
assert(A.cached({attachment_state=result.state,attachment_urls=result.urls,attachment_digest=result.digest}).digest==base)
assert(not pcall(A.cached,{attachment_state='partial',attachment_urls='',attachment_digest='bad'}))
assert(not pcall(A.cached,{attachment_digest=base}),'digest without attachment state accepted')
local cycle={};cycle.self=cycle;assert(not F.compute({pictures=cycle},present,array_mt))
assert(not F.compute({pictures={string.rep('x',F.MAX_BYTES+1)}},present,array_mt))
assert(not F.compute({pictures={[1]='a',[3]='b'}},present,array_mt))
assert(not F.compute({pictures={{unknown={}}}},present,nil),'ambiguous empty table accepted')
print('PASS: bounded canonical attachment identity and change detection')

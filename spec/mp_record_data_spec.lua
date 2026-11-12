package.path='./?.lua;'..package.path
local Data=require('weread.lib.mp_record_data')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local data=Data.read('-- synthetic record\nreturn { ["last_xpointer"]="/body/p.2", ["annotations"]={ [1]={ ["text"]="中文\\nquote", ["note"]="note", ["drawer"]="lighten" }, [2]={ ["page"]="/body/p.3" } }, ["number"]=-1.25e+2, ["enabled"]=false }')
expect(data.number==-125 and data.enabled==false and data.annotations[1].text=='中文\nquote','literal decoding changed values')
expect(Data.read('{["a"]=true, [2]="quote\\\" slash\\\\"}').a==true,'live dump without return rejected')
expect(Data.same(data,Data.read('--[[ header ]]\nreturn { ["last_xpointer"]="/body/p.2", ["annotations"]={ [1]={ ["text"]="中文\\nquote", ["note"]="note", ["drawer"]="lighten" }, [2]={ ["page"]="/body/p.3" } }, ["number"]=-1.25e+2, ["enabled"]=false }')),'comments changed record')
local summary=Data.summary('return { ["last_xpointer"]="/body", ["annotations"]={ [1]={ ["text"]="合成划线", ["drawer"]="lighten", ["pos0"]="/body/p.1", ["pos1"]="/body/p.2" }, [2]={ ["page"]="/body" } } }')
expect(summary.valid and summary.notes==1 and summary.bookmarks==1 and summary.has_position and summary.preview=='合成划线','preview lost record meaning')
summary=Data.summary('return {["annotations"]={[1]={["page"]="/body",["text"]="bookmark"},[2]={["drawer"]="lighten",["pos0"]="/body",["pos1"]="/body",["text"]="quote",["note"]="attached note"}}}')
expect(summary.preview=='quote' and summary.note_preview=='attached note','preview mixed a bookmark with another highlight note')
local emoji=string.rep('📖',80)
summary=Data.summary(string.format('return {["annotations"]={[1]={["drawer"]="lighten",["pos0"]="/body",["pos1"]="/body",["text"]=%q,["note"]=%q}}}',emoji,emoji))
expect(summary.preview==string.rep('📖',48) and summary.note_preview==summary.preview,'Unicode preview split or exceeded its limit')
for _i,raw in ipairs({'return os.execute("private-command")','while true do end','return (function() return {} end)()',
    'return {a=string.rep("x",100000)}','return { ["x"]="x".."x" }','return { ["x"]=2^100 }','return { ["x"]=1e999 }',
    'return { ["x"]=1+2 }','return { ["x"]=3-1 }',
    'return false','return {} return {}','return { ["x"]="unclosed }','return { ["x"]="bad" }\0'}) do
    local ok,reason=pcall(Data.read,raw);expect(not ok and reason=='mp_records/invalid_data','executable or malformed record accepted')
end
local deep=string.rep('{[1]=',Data.MAX_DEPTH+1)..'true'..string.rep('}',Data.MAX_DEPTH+1)
expect(not pcall(Data.read,deep),'deep metadata accepted')
expect(not pcall(Data.read,string.rep(' ',Data.MAX_BYTES+1)),'oversized metadata accepted')
expect(Data.summary('private bad record').valid==false,'corrupt archived record claimed usable')
for _i,raw in ipairs({'return {["annotations"]="bad"}','return {["annotations"]={[1]=false}}',
    'return {["annotations"]={[1]={["drawer"]="lighten"}}}',
    'return {["annotations"]={[1]={["text"]={}}}}','return {["last_xpointer"]=false}'}) do
    expect(not pcall(Data.record,raw) and not Data.summary(raw).valid,'malformed reading record was restorable')
end
expect(not Data.same({a=true},{a=false}) and not Data.same({a=true},{a=true,b=1}),'readback equality accepted changes')
print('PASS: non-executable KOReader record literals and previews ('..checks..' checks)')

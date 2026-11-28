package.path='./?.lua;'..package.path
local Model=require('weread.lib.translation_generation')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function copy(value) local result={};for k,v in pairs(value) do result[k]=v end;return result end
local hash=string.rep('a',64)
local plan={owner='123',book_id='456',chapter_uid=7,book_version=2,translate_version=0,
    grant_sha256=hash,catalog_sha256=hash,source_sha256=hash,baseline_sha256=hash}
expect(Model.valid(plan),'valid plan rejected')
local array_mt={}
local codec={json_decode=function() return setmetatable({},array_mt) end,
    json_encode=function(_self,value) return getmetatable(value)==array_mt and '[]' or '{}' end}
expect(not Model.generation_body(plan) and not Model.generation_body(plan,{json_decode=function() return {} end,
    json_encode=function() return '{}' end}),'ambiguous empty JSON object accepted as reference array')
local query=assert(Model.mode_query(plan))
expect(query.cbid=='456' and query.transFormat=='epubTranslate' and query.transType=='epubTranslate','mode query wrong')
local body=assert(Model.generation_body(plan,codec))
expect(body.bookId=='456' and #body.read==1 and body.read[1].uid==7 and body.read[1].translateVersion==0
    and body.reference.uid==7 and next(body.reference.texts)==nil and body.freeTrial==0,'generation not limited to one chapter')
for _,entry in ipairs({{'owner','01'},{'book_id','CB_1'},{'chapter_uid',0},{'chapter_uid',1.5},
    {'book_version',-1},{'translate_version',0/0},{'source_sha256','invalid'},{'extra',true}}) do
    local bad=copy(plan);bad[entry[1]]=entry[2]
    expect(not Model.valid(bad) and not Model.mode_query(bad) and not Model.generation_body(bad,codec),'invalid plan accepted: '..entry[1])
end
expect(Model.mode_ack({succ=true,bookId='456',vid=123},plan),'explicit matching mode acknowledgment rejected')
for _,value in ipairs({{}, {succ=false}, {succ=true,code=1}, {succ=true,bookId='999'}, {succ=true,vid='999'}, {succ='1'}}) do
    expect(not Model.mode_ack(value,plan),'unconfirmed or mismatched mode acknowledgment accepted')
end
local function kind(value,expected)
    local result=Model.status(value,plan)
    expect(result and result.kind==expected,'wrong generation state: '..expected)
    return result
end
kind({stopPoll=1},'stopped_unavailable')
kind({stopPoll=0,curStatus={{uid=7,translateVersion=0}}},'pending')
kind({data={stopPoll=true,curStatus={{uid=7,translateVersion=1}}}},'ready')
kind({translationProgress=100},'pending')
for _,value in ipairs({{}, {succ=false,stopPoll=1}, {stopPoll='1'}, {stopPoll=true,curStatus={{uid=8,translateVersion=1}}},
    {stopPoll=true,curStatus={{uid=7,translateVersion=1},{uid=7,translateVersion=1}}},
    {stopPoll=true,curStatus=false}, {stopPoll=true,curStatus={[2]={uid=7,translateVersion=1}}}, {stopPoll=true,curStatus={{uid=7,translateVersion=-1}}},
    {stopPoll=true,tips=string.rep('x',8193)}, {data={},result={}}, {data={vid='999',stopPoll=true}}}) do
    expect(not Model.status(value,plan),'malformed or mismatched status accepted')
end
local later=copy(plan);later.translate_version=3
expect(not Model.status({stopPoll=true,curStatus={{uid=7,translateVersion=2}}},later),'version regression accepted')
expect(Model.status({stopPoll=true,curStatus={{uid=7,translateVersion=3}}},later).kind=='ready',
    'available existing version rejected')
print('PASS: single-chapter translation generation model ('..checks..' checks)')

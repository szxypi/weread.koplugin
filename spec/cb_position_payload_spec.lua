package.path='./?.lua;'..package.path
local Payload=require('weread.lib.cb_position_payload')
local Protocol=require('weread.lib.protocol')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function copy(value) local out={} for k,v in pairs(value) do out[k]=v end return out end
local summary='合成的长摘要用于检查完整内容能够被保留，包括换行。\n'..string.rep('文',30)..'😀'
local options={book_id='CB_Synthetic',chapter_uid='7',chapter_idx=2,chapter_offset=18,progress=37,
    summary=summary,psvts='synthetic-session',pclts='synthetic-clock',token='synthetic-token',now=1700000000}
for _,stage in ipairs({'enter','position'}) do
    local value=copy(options)
    if stage=='position' then value.ts=1700000000123;value.rn=13 end
    local out=Payload.build(stage,value)
    expect(out.sm==summary and #out.sm>20,'full Unicode summary was truncated')
    expect(out.s==Protocol.sign(Protocol.sorted_query(out)),'full summary was excluded from signature')
    expect(out.co==18 and out.c==Protocol.e('7') and out.b==Protocol.e('CB_Synthetic'),'position identity changed')
    if stage=='position' then expect(out.rt==0 and out.ts==value.ts and out.rn==value.rn,'position duration/random changed')
    else expect(out.rt==nil and out.ts==nil and out.sg==nil,'enter leaked report fields') end
end
local limit=copy(options);limit.summary=string.rep('😀',512)
expect(Payload.build('enter',limit).sm==limit.summary,'maximum bounded summary was truncated')
local duration=copy(options);duration.elapsed_seconds=999;duration.ts=1700000000123;duration.rn=13
expect(Payload.build('position',duration).rt==0,'caller supplied nonzero duration')
local short=copy(options);short.summary='ordinary summary'
local old=Protocol.make_enter_read_payload(short);local new=Payload.build('enter',short)
expect(old.sm==new.sm and old.s==new.s,'short summary changed normal wire format')
for _,change in ipairs({{book_id='900001'},{book_id='CB_bad/'},{book_id='CB_'},{chapter_uid='x'},{chapter_uid='0'},
    {chapter_idx=-1},{chapter_idx=1.5},{chapter_offset=-1},{progress=1.2},{progress=101},{summary=''},
    {summary=string.rep('x',2049)},{summary=string.rep('文',513)},{summary='invalid\255'},
    {summary='bad\0control'},{psvts=''},{psvts='a b'},{pclts=''},{token='short'},{token=false},
    {now=0},{now=false},{now=math.huge}}) do
    local value=copy(options);for key,item in pairs(change) do value[key]=item end
    expect(not pcall(Payload.build,'enter',value),'invalid payload input was accepted')
end
for _,change in ipairs({{rn=-1},{rn=1000},{ts=1700000001123},{ts=0}}) do
    local value=copy(options);for key,item in pairs(change) do value[key]=item end
    expect(not pcall(Payload.build,'position',value),'invalid timestamp or random was accepted')
end
local extra=copy(options);extra.ts=1700000000123
expect(not pcall(Payload.build,'enter',extra),'enter accepted report-only random fields')
expect(not pcall(Payload.build,'other',options),'unknown payload stage accepted')
print('cb_position_payload_spec: '..checks..' checks')

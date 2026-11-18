package.path='./?.lua;'..package.path
local Payload=require('weread.lib.cb_readtime_payload')
local Position=require('weread.lib.cb_position_payload')
local Protocol=require('weread.lib.protocol')
local n=0;local function expect(value,message) n=n+1;assert(value,message or ('check '..n)) end
local options={book_id='CB_Synthetic',chapter_uid='7',chapter_idx=2,chapter_offset=18,progress=37,
    summary='合成摘要😀'..string.rep('文',30),psvts='synthetic-session',pclts='synthetic-clock',
    token='synthetic-token',now=1700000000,ts=1700000000123,rn=13}
for _,seconds in ipairs({1,2,30,86400}) do
    local value=Payload.build(options,seconds)
    expect(value.rt==seconds and value.sm==options.summary,'time payload changed duration or summary')
    local signature=value.s;value.s=nil;expect(signature==Protocol.sign(Protocol.sorted_query(value)),'time payload signature omitted duration')
end
for _,seconds in ipairs({0,-1,1.5,86401,math.huge,false,'2'}) do
    expect(not pcall(Payload.build,options,seconds),'invalid duration was accepted')
end
expect(Position.build('position',options).rt==0,'time path changed position-only behavior')
local bad={};for key,value in pairs(options) do bad[key]=value end;bad.book_id='900001'
expect(not pcall(Payload.build,bad,2),'ordinary book passed CB payload validation')
print('cb_readtime_payload_spec: '..n..' checks')

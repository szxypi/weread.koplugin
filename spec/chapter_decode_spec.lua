package.path='./?.lua;'..package.path
local Decode=require('weread.lib.chapter_decode')
local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

-- Independent copy of the previous decoder, including its permissive
-- handling of invalid bytes and padding anywhere in the input.
local function old_base64(data)
    data=data:gsub('-','+'):gsub('_','/')
    local pad=#data%4;if pad>0 then data=data..string.rep('=',4-pad) end
    data=data:gsub('[^'..alphabet..'=]','')
    return (data:gsub('.',function(char)
        if char=='=' then return '' end
        local bits='';local index=alphabet:find(char,1,true)-1
        for bit=6,1,-1 do bits=bits..(index%2^bit-index%2^(bit-1)>0 and '1' or '0') end
        return bits
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?',function(bits)
        if #bits~=8 then return '' end
        local byte=0
        for i=1,8 do if bits:sub(i,i)=='1' then byte=byte+2^(8-i) end end
        return string.char(byte)
    end))
end
local function old_swaps(encoded,positions)
    local chars={};for i=1,#encoded do chars[i]=encoded:sub(i,i) end
    for i=#positions,1,-2 do for k=1,0,-1 do
        local left,right=positions[i]+k+1,positions[i-1]+k+1
        chars[left],chars[right]=chars[right],chars[left]
    end end
    return table.concat(chars)
end
local function old_positions(encoded)
    local length=#encoded
    if length<4 then return {} end
    if length<11 then return {0,2} end
    local n=math.min(4,math.floor((length+9)/10));local tmp={}
    for i=length,length-n+1,-1 do
        local byte=encoded:byte(i);local bin={}
        repeat table.insert(bin,1,tostring(byte%2));byte=math.floor(byte/2) until byte==0
        tmp[#tmp+1]=tostring(tonumber(table.concat(bin),4) or 0)
    end
    tmp=table.concat(tmp)
    local result={};local m=length-n-2;local step=#tostring(m);local i=1
    while #result<10 and i+step-1<#tmp do
        result[#result+1]=(tonumber(tmp:sub(i,i+step-1)) or 0)%m
        local finish=math.min(i+step,#tmp)
        if i+1<=#tmp then result[#result+1]=(tonumber(tmp:sub(i+1,finish)) or 0)%m end
        i=i+step
    end
    return result
end

local cases={'','A','AA','AAA','AAAA','AA==','A=A=A=A','_=/-','\0\255\nA?B',
    'SGVsbG8gV29ybGQ=','5Lit5paH8J-Zgg==','====','a=!!a\0a'}
local seed=1234567
local function random(n) seed=(seed*48271)%2147483647;return seed%n end
for _=1,5000 do
    local length=random(300);local chars={}
    for i=1,length do
        if random(4)==0 then chars[i]=string.char(random(256))
        else local at=random(#alphabet)+1;chars[i]=alphabet:sub(at,at) end
    end
    cases[#cases+1]=table.concat(chars)
end
for _,input in ipairs(cases) do
    assert(Decode.base64(input)==old_base64(input),'base64 output changed')
    local encoded=input:sub(2);local positions=Decode.swap_positions(encoded)
    local reference=old_positions(encoded)
    assert(#positions==#reference,'position count changed')
    for i,value in ipairs(reference) do assert(positions[i]==value,'swap position changed') end
    assert(Decode.reverse_swaps(encoded,positions)==old_swaps(encoded,positions),'payload swaps changed')
    local expected=#input==0 and '' or old_base64(old_swaps(encoded,positions))
    assert(Decode.decode_payload(input)==expected,'complete payload changed')
end
local Content=require('weread.lib.content')
local Crypto=require('weread.lib.crypto')
local function shard(value) return Crypto.md5_hex(value):upper()..value end
for i=1,#cases,50 do
    local body=cases[i]
    local first,second=math.floor(#body/3),math.floor(#body*2/3)
    local e0,e1,e3=shard(body:sub(1,first)),shard(body:sub(first+1,second)),shard(body:sub(second+1))
    assert(Content.decode_content_shards(e0,e1,e3)==Decode.decode_payload(body),'split shard output changed')
    if #e0>32 then
        assert(not pcall(Content.decode_content_shards,string.rep('F',32)..e0:sub(33),e1,e3),
            'corrupt shard bypassed checksum')
    end
end
-- Include repeated, adjacent and self-swaps whose order must remain exact.
for length=2,128 do
    local data={};for i=1,length do data[i]=string.char((i*17)%256) end;data=table.concat(data)
    for _=1,40 do
        local positions={};for _pair=1,5 do
            positions[#positions+1]=random(length-1);positions[#positions+1]=random(length-1)
        end
        assert(Decode.reverse_swaps(data,positions)==old_swaps(data,positions),'overlapping swaps changed')
    end
end
print(('chapter_decode_spec: %d payloads and 5080 overlapping-swap cases passed'):format(#cases))

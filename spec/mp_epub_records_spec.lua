package.path='./?.lua;'..package.path
local M=require('weread.lib.mp_epub_records')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function p16(n) return string.char(n%256,math.floor(n/256)%256) end
local function p32(n) return p16(n%65536)..p16(math.floor(n/65536)) end
local key=string.rep('a',64);local nonce='0123456789abcdef'
local function fixture(options)
    options=options or {};local locals,central,offset={},{},0
    for index,row in ipairs({{'mimetype','application/epub+zip'},{'META-INF/container.xml','<container/>'},
        {'EPUB/章节.xhtml','<html><body>原文、图片及位置</body></html>'},{'EPUB/images/',''}}) do
        local name=options.name and index==3 and options.name or row[1]
        local data=index==3 and options.large and string.rep(row[2],4096) or row[2]
        local extra=index==2 and (options.extra or p16(0x1234)..p16(3)..'xyz') or ''
        local flags=options.flags or 0;local descriptor=options.descriptor
        if descriptor then flags=flags+8 end
        local crc,size=123,#data
        local local_sizes=descriptor and p32(0)..p32(0)..p32(0) or p32(crc)..p32(size)..p32(size)
        local raw='PK\3\4'..p16(20)..p16(flags)..p16(0)..p32(0)..local_sizes..p16(#name)..p16(#extra)..name..extra..data
        if descriptor then raw=raw..(options.untagged and '' or 'PK\7\8')..p32(crc)..p32(size)..p32(size) end
        locals[#locals+1]=raw
        central[#central+1]='PK\1\2'..p16(20)..p16(20)..p16(flags)..p16(0)..p32(0)..p32(crc)..p32(size)..p32(size)
            ..p16(#name)..p16(0)..p16(0)..p16(0)..p16(0)..p32(0)..p32(offset)..name
        offset=offset+#raw
    end
    local cd=table.concat(central);local comment=options.comment or ''
    return table.concat(locals)..cd..'PK\5\6'..p16(0)..p16(0)..p16(#central)..p16(#central)..p32(#cd)..p32(offset)..p16(#comment)..comment
end
local function reader(raw)
    return function(at,n) local value=raw:sub(at+1,at+n);assert(#value==n,'out-of-bounds read');return value end
end
local function copy(raw,value,copy_key)
    local plan=M.plan(reader(raw),#raw,copy_key or key,value or nonce);local out={};local maximum=0
    local count=M.apply(reader(raw),function(chunk) maximum=math.max(maximum,#chunk);out[#out+1]=chunk;return true end,plan)
    local result=table.concat(out);assert(count==#result and maximum<=65536)
    return result,plan
end
for _i,options in ipairs({{}, {descriptor=true},{descriptor=true,untagged=true},{flags=2048},{comment='kept comment'},{large=true}}) do
    local raw=fixture(options);local cloned,plan=copy(raw)
    expect(M.header(cloned:sub(1,1024),key,nonce)==nonce,'new header identity not in first sample')
    expect(not M.header(cloned,key,string.rep('f',16)) and not M.header(cloned,string.rep('b',64)),'foreign header accepted')
    local parsed=M.plan(reader(cloned),#cloned,key,string.rep('f',16))
    expect(#parsed.entries==#plan.entries and parsed.expanded==plan.expanded,'entry inventory or expanded size changed')
    for index,row in ipairs(plan.entries) do
        local later=parsed.entries[index]
        expect(row.name==later.name and row.size==later.size and row.crc==later.crc
            and raw:sub(row.head.data+1,row.head.data+row.compressed)==cloned:sub(later.head.data+1,later.head.data+later.compressed),
            'copy changed an original compressed member')
    end
    local again=copy(cloned,string.rep('f',16))
    expect(#again==#cloned and M.header(again,key)==string.rep('f',16),'recovery identity accumulated or retained old nonce')
    expect(not options.comment or cloned:sub(-#options.comment)==options.comment,'ZIP comment changed')
end
for _i,options in ipairs({{name='../private'},{name='/private'},{name='EPUB//file'},{name='EPUB/./file'},
    {name='C:\\private'},{name='mimetype'},{flags=1},{flags=0x40},{extra=p16(1)..p16(0)},
    {extra=p16(0x1234)..p16(9)..'short'},{extra=p16(M.EXTRA_ID)..p16(7)..'foreign'},
    {name='EPUB/'..string.rep('x',1025)}}) do
    local raw=fixture(options)
    expect(not pcall(M.plan,reader(raw),#raw,key,nonce),'unsafe archive header accepted')
end
local raw=fixture()
for _i,value in ipairs({'','x','UPPERCASE0123456',string.rep('a',17)}) do
    expect(not pcall(M.plan,reader(raw),#raw,key,value),'invalid version nonce accepted')
end
expect(not pcall(M.plan,reader(raw),#raw,string.rep('b',63),nonce),'invalid article key accepted')
expect(not pcall(M.plan,reader(raw),#raw-1,key,nonce),'truncated end record accepted')
expect(not pcall(M.plan,reader(raw),M.MAX_ARCHIVE+1,key,nonce),'archive bound ignored')
local plan=M.plan(reader(raw),#raw,key,nonce)
expect(not pcall(M.apply,reader(raw),function() return false end,plan),'failed output write accepted')
local malformed=raw:gsub('PK\1\2','BAD!',1)
expect(not pcall(M.plan,reader(malformed),#malformed,key,nonce),'damaged central directory accepted')
malformed=raw:gsub('META%-INF/container%.xml','META-INF/unrelated.xml')
expect(not pcall(M.plan,reader(malformed),#malformed,key,nonce),'missing container accepted')
local cloned=copy(raw)
expect(not pcall(M.plan,reader(cloned),#cloned,string.rep('b',64),nonce),'foreign existing copy identity promoted')
expect(not M.header(raw,key) and not M.header('PK\3\4',key),'unmarked or truncated body accepted as managed')
print('PASS: EPUB member-preserving ZIP identity and boundaries ('..checks..' checks)')

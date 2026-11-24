require('ffi').log=function() end
require('setupkoenv')
package.path=arg[1]..'/?.lua;'..package.path
local baseline=assert(loadfile(arg[2]))()
local current=require('weread.lib.source_coordinates')
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for key,value in pairs(a) do if not equal(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function decode(entity)
    return ({['&amp;']='&',['&nbsp;']=' ',['&x;']='e\204\129'})[entity] or entity
end
local samples={
    {'<body><p>中文搜索与页面位置，唯一段落甲乙丙丁戊己庚辛壬癸。</p><p>重复重复重复重复重复重复重复。</p></body>'},
    {'<body><p>超过边界的文本 > 文字 &amp; 后续内容。<i>斜体中间段落</i> 间隔段落结束。</p><p>另外一个长段落。</p></body>'},
    {'<body><p>开始'..(' '):rep(600)..'结尾唯一正文甲乙丙丁戊己庚辛壬癸。</p><p>尾段文字甲乙丙丁戊己庚辛壬癸。</p></body>'},
    {'<body><p>'..('甲'):rep(270)..'&x;Unicode 😀 片段甲乙丙丁戊己庚辛壬癸'..('乙'):rep(280)..'</p></body>'},
    {'<body><div>😀Emoji 与空格\n以及 &nbsp; e\204\129 以及尾部唯一文字甲乙丙丁戊己庚辛壬癸。</div></body>'},
    {'<body><p>incomplete \240\159</p></body>'},
    {('起'):rep(260)..(' '):rep(530)..'😀 TXT 字面 &amp; 和唯一正文甲乙丙丁戊己庚辛壬癸。','web_txt'},
    {'<html><body><p>第一段独特正文包含 &amp; 符号与足够长度。</p></body></html>'
        ..'<html><body><p>第二段独特正文包含 😀 和足够的中文内容。</p></body></html>','web_xhtml',true},
    {'<body><p>'..('>'):rep(16)..'第一段唯一正文足够长以判断坐标。</p>'
        ..'<p>相邻第二段唯一正文足够长以判断坐标。</p></body>','web_xhtml',false,true},
}
local comparisons=0
for _,sample in ipairs(samples) do
    local raw=sample[1]
    local options={format=sample[2] or 'web_xhtml',decode_entity=decode,allow_multiple_bodies=sample[3]}
    local old,old_error=baseline.build(raw,options)
    local new,new_error=current.build(raw,options)
    assert((old~=nil)==(new~=nil) and old_error==new_error,'build mismatch')
    if old then
        assert(old.flat==new.flat,'flat text changed')
        if sample[4] then
            local overlap=false
            for a=1,#new.anchor_blocks,6 do
                for b=a+6,#new.anchor_blocks,6 do
                    local blocks=new.anchor_blocks
                    if blocks[a]~=blocks[b] and blocks[a+3]<blocks[b+4] and blocks[b+3]<blocks[a+4] then overlap=true end
                end
            end
            assert(overlap,'overlapping source intervals were not exercised')
        end
        local positions={}
        local function add(co) if co>=0 and co<=#raw*2 then positions[co]=true end end
        if #raw<400 then for co=0,#raw*2 do add(co) end
        else
            for co=0,80 do add(co) end
            for co=230,290 do add(co) end
            for i=1,300 do add((i*619+73)%(#raw*2+1)) end
            local blocks=new.anchor_blocks
            for block=1,#blocks,6 do
                for delta=-1,1 do add(blocks[block+3]+delta);add(blocks[block+4]+delta) end
            end
        end
        for co in pairs(positions) do
            for _,segment_only in ipairs({false,true}) do
                local a,ae=old:anchor(co,{segment_only=segment_only})
                local b,be=new:anchor(co,{segment_only=segment_only})
                assert(ae==be and equal(a,b),'anchor result changed')
                comparisons=comparisons+1
            end
        end
    end
end
local parts={'<html><body>'}
for i=1,500 do
    parts[#parts+1]=('<p>第%04d章唯一内容%s第%04d章结束</p>'):format(i,('这是测试文字用于建立页面位置和阅读记录。'):rep(15),i)
end
parts[#parts+1]='</body></html>'
local raw=table.concat(parts)
local result={comparisons=comparisons,body_bytes=#raw,anchors_per_run=20,runs=3,cases={}}
for _,case in ipairs({{'baseline',baseline},{'optimized',current}}) do
    local rows={}
    for _=1,3 do
        collectgarbage('collect');local memory=collectgarbage('count')
        local start=os.clock();local map=assert(case[2].build(raw));local build=os.clock()-start
        collectgarbage('collect');memory=collectgarbage('count')-memory
        local original=map._token;local calls=0
        map._token=function(...) calls=calls+1;return original(...) end
        start=os.clock()
        for i=1,20 do
            local target=('第%04d章唯一内容'):format(i*20)
            local byte=assert(map.flat:find(target,1,true))
            local co=map:_point(byte)
            local anchor,why=map:anchor(co,{segment_only=true})
            assert(anchor and anchor.co==co,why)
        end
        rows[#rows+1]={build_seconds=build,anchor_seconds=os.clock()-start,token_calls=calls,lua_kib=memory}
    end
    result.cases[case[1]]=rows
end
io.write('\nWEREAD_ANCHOR_BENCHMARK='..require('json').encode(result)..'\n')

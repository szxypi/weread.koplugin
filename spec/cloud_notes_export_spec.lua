package.path='./?.lua;'..package.path
local Model=require('weread.lib.cloud_notes_export')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local null,array={},{}
local function rows(value) return setmetatable(value or {},array) end
local encoded={}
local codec={json_decode=function(_self,value) return value=='null' and null or rows() end,
    json_encode=function(_self,value) encoded[#encoded+1]=value;return '{}' end}
local marks={schema=1,book_id='CB_Synthetic',fetched_at=1000,chapters=rows{{chapterUid=2,title='Chapter <one>'}},
    updated=rows{{bookmarkId='secret-mark-id',type=1,chapterUid=2,markText='quote\r\nline [link](x)',abstract='other',
        range='1-2',style=2,colorStyle=3,createTime=900},{bookmarkId='secret-bookmark-id',type=0,chapterUid=2}}}
local thoughts={schema=1,book_id='CB_Synthetic',fetched_at=1001,reviews=rows{{reviewId='secret-review-id',chapterUid=2,
    content='Thought <script>',abstract='quoted\ntext',isPrivate=1,createTime=901}}}
local input={book_id='CB_Synthetic',book={title='Test <book>',author='Author'},now=0,marks=marks,thoughts=thoughts}
local function run(format,value,sink)
    local chunks={};encoded={}
    local result=Model.write(value or input,format,codec,sink or function(part) chunks[#chunks+1]=part;return true end)
    return table.concat(chunks),result,encoded
end
local json,result,values=run('json')
expect(json=='{"schema":1,"source":"WeRead","book":{},"snapshots":{},"marks":[{},{}],"thoughts":[{}]}\n'
    and result.count==3 and result.bytes==#json,'JSON sections or item count changed')
expect(values[2].marks.available and values[2].marks.fetched_at==1000 and values[2].thoughts.available,
    'saved snapshot status was lost')
expect(values[3].kind=='highlight' and values[3].text==marks.updated[1].markText and values[3].style==2
    and values[3].color_style==3 and values[4].kind=='bookmark','mark data or bookmark was lost')
expect(values[5].content=='Thought <script>' and values[5].visibility=='private' and values[5].chapter=='Chapter <one>',
    'thought, visibility or chapter mapping was lost')
for _i,item in ipairs(values) do
    expect(not item.book_id and not item.bookmarkId and not item.reviewId and not item.range,
        'account-bound identity or coordinates leaked into export')
end
local md=run('markdown')
expect(md:find('> quote\n> line',1,true) and md:find('&lt;script&gt;',1,true)
    and not md:find('<script>',1,true) and md:find('Private',1,true),'Markdown content was unsafe or incomplete')
local partial={book_id=input.book_id,book=input.book,marks=marks,now=0}
md,result=run('markdown',partial)
expect(result.count==2 and md:find('Not saved on this device',1,true),'missing thought snapshot was hidden')
local partial_json,partial_result
partial_json,partial_result,values=run('json',partial)
expect(partial_json~='' and partial_result.count==2 and values[2].marks.available and not values[2].thoughts.available and values[2].thoughts.fetched_at==nil,
    'JSON hid the missing snapshot or invented its time')
local far_future={schema=1,book_id=input.book_id,fetched_at=5000000000,updated=marks.updated,chapters=marks.chapters}
local future_md=run('markdown',{book_id=input.book_id,marks=far_future,now=0})
expect(future_md:find('Time unavailable',1,true),'out-of-range timestamp was silently omitted')
local function fails(task) local ok=pcall(task);expect(not ok,'invalid export was accepted') end
fails(function() run('json',{book_id='CB_Other',marks=marks}) end)
fails(function() run('json',{book_id=input.book_id}) end)
fails(function() run('json',{book_id=input.book_id,marks=marks,thoughts=false}) end)
fails(function() run('json',{book_id=input.book_id,marks={schema=1,book_id=input.book_id,fetched_at=1,updated=rows(),chapters=rows()}}) end)
fails(function() run('html') end)
fails(function() run('json',input,function() return false end) end)
local maximum=Model.MAX_OUTPUT_BYTES;Model.MAX_OUTPUT_BYTES=8
fails(function() run('markdown') end);Model.MAX_OUTPUT_BYTES=maximum
print('cloud_notes_export_spec: '..checks..' checks')

package.path='./?.lua;'..package.path
local View=require('weread.lib.source_view')
local checks=0;local function expect(value,why) checks=checks+1;assert(value,why) end
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
end
local point={book_id='900001',chapter_uid='2',chapter_offset=120,book_version=7,file_id=string.rep('a',64),
    raw_sha256=string.rep('b',64),render_path='OEBPS/text/chapter.xhtml',basis='raw_txt_utf16',upload_verified=false}
local frame={page=2,pos=600,view_mode='page',xpointer='/body/p/text().1',rendering_hash=12345,pages=10,height=6000,viewport_height=800}
local owner=string.rep('c',20);local proof=assert(View.capture(frame,owner,point))
expect(View.matches(proof,copy(frame),owner,copy(point)),'same local view did not match')
for key,value in pairs({page=3,pos=601,view_mode='scroll',xpointer='/body/p/text().2',rendering_hash=12346,pages=11,height=6001,viewport_height=900}) do
    local moved=copy(frame);moved[key]=value
    expect(not View.matches(proof,moved,owner,point),'changed native view accepted: '..key)
end
for key,value in pairs({book_id='900002',chapter_uid='3',chapter_offset=121,book_version=8,file_id=string.rep('d',64),
    raw_sha256=string.rep('e',64),render_path='OEBPS/text/other.xhtml',basis='filtered_xhtml_utf16',upload_verified=true}) do
    local changed=copy(point);changed[key]=value
    expect(not View.matches(proof,frame,owner,changed),'changed source accepted: '..key)
end
expect(not View.matches(proof,frame,string.rep('d',20),point),'foreign account matched local proof')
for _,key in ipairs({'xpointer','rendering_hash','height','pages','pos','viewport_height'}) do
    local unknown=copy(frame);unknown[key]=nil
    expect(not View.capture(unknown,owner,point) and not View.matches(proof,unknown,owner,point),'unknown layout reused source point')
end
for _,change in ipairs({{page=0},{page=11},{pos=-1},{height=0/0},{viewport_height=math.huge},{rendering_hash=false},{xpointer='bad\npoint'}}) do
    local bad=copy(frame);for k,v in pairs(change) do bad[k]=v end
    expect(not View.capture(bad,owner,point),'invalid native view accepted')
end
local modified=copy(proof);modified.extra='private'
expect(not View.matches(modified,frame,owner,point),'extra receipt fields accepted')
modified=copy(proof);modified.view.extra='private'
expect(not View.matches(modified,frame,owner,point),'extra viewport fields accepted')
modified=copy(proof);modified.schema=2
expect(not View.matches(modified,frame,owner,point),'unknown proof version accepted')
proof.view.page=3;expect(frame.page==2,'captured view aliases native frame')
expect(proof.summary==nil and proof.accessToken==nil and proof.chapter_offset==nil,'proof retained private text or cloud authority')
print('source_view_spec: '..checks..' checks')

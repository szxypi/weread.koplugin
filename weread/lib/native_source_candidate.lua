-- Pure raw TXT candidate. Caller must retain SourcePosition's opaque receipt
-- and recheck current source/catalog/auth before a native operation is begun.
local Protocol=require('weread.lib.native_position_protocol')
local Catalog=require('weread.lib.source_upload_candidate')
local Coordinates=require('weread.lib.source_coordinates')
local M={}
local function exact(value,fields)
    if type(value)~='table' then return false end
    local n=0;for key in pairs(value) do if not fields[key] then return false end;n=n+1 end
    local count=0;for _key in pairs(fields) do count=count+1 end;return n==count
end
local point_fields={book_id=true,chapter_uid=true,chapter_offset=true,file_id=true,book_version=true,
    raw_sha256=true,render_path=true,basis=true,upload_verified=true}
local excerpt_fields={text=true,co=true,end_co=true,scalars=true,basis=true,upload_verified=true}
local function hash(v) return type(v)=='string' and #v==64 and v:match('^[a-f0-9]+$') end
function M.project(packet,chapters,percent)
    if not exact(packet,{position=true,excerpt=true}) or not exact(packet.position,point_fields)
        or not exact(packet.excerpt,excerpt_fields) then return nil end
    local p,e=packet.position,packet.excerpt
    if p.basis~='raw_txt_utf16' or p.upload_verified~=false or e.basis~=p.basis or e.upload_verified~=false
        or e.co~=p.chapter_offset or not hash(p.file_id) or not hash(p.raw_sha256)
        or not Protocol.integer(p.book_version,0,2147483647) or not Protocol.integer(percent,0,100)
        or type(p.render_path)~='string' or #p.render_path>128
        or not (p.render_path=='OEBPS/text/chapter.xhtml' or p.render_path:match('^OEBPS/text/chapter%-%d%d%d%d?%d?%d?%.xhtml$'))
        or type(e.text)~='string' or #e.text<1 or #e.text>120 then return nil end
    local map=Coordinates.build(e.text,{format='web_txt'});local expected=map and map:literal_excerpt(0)
    if not expected or expected.text~=e.text or expected.scalars~=e.scalars or p.chapter_offset+expected.end_co~=e.end_co then return nil end
    local index=Catalog.chapter_index(chapters,p.chapter_uid);if index==nil then return nil end
    local ok,point=pcall(Protocol.point,{book_id=p.book_id,chapter_uid=p.chapter_uid,chapter_idx=index,
        chapter_offset=p.chapter_offset,raw_percent=percent,summary=e.text})
    if not ok or point.book_id~=p.book_id or point.chapter_uid~=p.chapter_uid then return nil end
    point.basis,point.upload_verified='raw_txt_utf16',false
    return point
end
return M

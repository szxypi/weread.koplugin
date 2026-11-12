-- Local-only exact source point tied to an unchanged native viewport.
-- This is neither a cloud comparison nor an upload/authentication receipt.
local Crypto=require('weread.lib.crypto')
local Source=require('weread.lib.position_source')
local M={}
local keys={'page','pos','view_mode','xpointer','rendering_hash','pages','height','viewport_height'}
local function integer(v,minimum,maximum) return type(v)=='number' and v==v and v%1==0 and v>=minimum and v<=maximum end
local function text(v,maximum) return type(v)=='string' and #v>0 and #v<=maximum and not v:find('[%z%c]') end
local function hash(v,n) return type(v)=='string' and #v==n and v:match('^[a-f0-9]+$')~=nil end
local function point_hash(point)
    if type(point)~='table' or not Source.is_coordinate_basis(point.basis) or point.upload_verified~=false
        or not integer(point.chapter_offset,0,2147483647) or not integer(point.book_version,0,2147483647)
        or not hash(point.file_id,64) or not hash(point.raw_sha256,64) then return end
    local parts={'source-view-v1'}
    for _i,key in ipairs({'book_id','chapter_uid','render_path','basis'}) do
        if not text(point[key],1024) then return end;parts[#parts+1]=point[key]
    end
    for _i,key in ipairs({'chapter_offset','book_version','file_id','raw_sha256'}) do parts[#parts+1]=tostring(point[key]) end
    return Crypto.sha256_hex(table.concat(parts,'\0'))
end
local function valid(frame)
    if type(frame)~='table' or not text(frame.xpointer,4096) or frame.view_mode~='page' and frame.view_mode~='scroll'
        or not integer(frame.page,1,1000000) or not integer(frame.pages,1,1000000) or frame.page>frame.pages
        or not integer(frame.pos,0,2147483647) or not integer(frame.height,1,2147483647)
        or not integer(frame.viewport_height,1,65536)
        or not (text(frame.rendering_hash,128) or integer(frame.rendering_hash,0,9007199254740990)) then return false end
    for key in pairs(frame) do
        local found=false;for _i,name in ipairs(keys) do if key==name then found=true;break end end
        if not found then return false end
    end
    return true
end
function M.capture(frame,owner,point)
    local fingerprint=point_hash(point)
    if not hash(owner,20) or not fingerprint or not valid(frame) then return end
    local view={};for _i,key in ipairs(keys) do view[key]=frame[key] end
    return {schema=1,owner=owner,point_sha256=fingerprint,view=view}
end
function M.matches(proof,frame,owner,point)
    if type(proof)~='table' or proof.schema~=1 or not hash(owner,20) or proof.owner~=owner
        or not hash(proof.point_sha256,64) or proof.point_sha256~=point_hash(point) or not valid(proof.view) or not valid(frame) then return false end
    for key in pairs(proof) do if key~='schema' and key~='owner' and key~='point_sha256' and key~='view' then return false end end
    for _i,key in ipairs(keys) do if proof.view[key]~=frame[key] then return false end end
    return true
end
return M

-- Bounded, full-summary CB_ Web payload construction. Pure DTO only: this
-- module grants no upload authority and performs no network or persistence.
local Protocol=require('weread.lib.protocol')
local Access=require('weread.lib.read_access')
local Native=require('weread.lib.native_position_protocol')
local M={}
local function fail(reason) error('cb_position_payload/'..reason,0) end
local function integer(value,low,high)
    return type(value)=='number' and value==value and value%1==0 and value>=low and value<=high
end
local function printable(value,minimum)
    return type(value)=='string' and #value>=minimum and #value<=4096 and not value:find('[^!-~]')
end
function M.build(stage,opts)
    if stage~='enter' and stage~='position' or type(opts)~='table' then fail('invalid') end
    local id=Access.display_book_id(opts.book_id)
    local chapter=Access.book_id(opts.chapter_uid)
    if not id or id:sub(1,3)~='CB_' or not chapter or not integer(opts.chapter_idx,0,1000000)
        or not integer(opts.chapter_offset,0,2147483647) or not integer(opts.progress,0,100)
        or not Native.summary(opts.summary) or not printable(opts.psvts,1) then fail('invalid') end
    local pc=opts.pclts
    if type(pc)=='number' then
        if not integer(pc,1,9007199254740991) then fail('invalid') end
    elseif not printable(pc,1) then fail('invalid') end
    local token=opts.token
    if token==nil then token=Protocol.DEFAULT_READER_TOKEN end
    if not printable(token,8) then fail('invalid') end
    local now=opts.now
    if now==nil then now=os.time() end
    if not integer(now,1,4102444800) then fail('invalid') end
    if stage=='position' then
        if opts.rn~=nil and not integer(opts.rn,0,999) then fail('invalid') end
        if opts.ts~=nil and (not integer(opts.ts,1000,4102444800999) or math.floor(opts.ts/1000)~=now) then fail('invalid') end
    elseif opts.ts~=nil or opts.rn~=nil then fail('invalid') end
    local fields={book_id=id,chapter_uid=chapter,chapter_idx=opts.chapter_idx,chapter_offset=opts.chapter_offset,
        progress=opts.progress,summary=opts.summary,psvts=opts.psvts,pclts=pc,token=token,
        now=now,ts=opts.ts,rn=opts.rn,elapsed_seconds=0}
    local result=stage=='enter' and Protocol.make_enter_read_payload(fields) or Protocol.make_read_payload(fields)
    result.sm=opts.summary
    result.s=Protocol.sign(Protocol.sorted_query(result))
    return result
end
return M

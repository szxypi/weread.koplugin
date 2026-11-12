-- Local planning only. No HTTP, claims, queue transitions or version upgrades.
local C=require('weread.lib.readtime_transfer_contract')
local Coverage=require('weread.lib.readtime_coverage')
local M={};M.__index=M
function M:new(options)
    return setmetatable({ledger=assert(options.ledger),coverage=assert(options.coverage),now=options.now or os.time},self)
end
local function same(row,group)
    return not group.book_id or row.book_id==group.book_id and row.file_id==group.file_id
        and row.book_version==group.book_version and row.time_zone==group.time_zone
end
function M:select(account,book_id)
    if not C.account(account) or book_id~=nil and not C.id(book_id) then return nil,'invalid_selection' end
    local now=self.now()
    if not C.integer(now,1,4102444800) then return nil,'invalid_clock' end
    local selected={rows={},parts={},seconds=0};local report={scanned=0,unsupported=0,conflicting=0,covered=0,untracked=0}
    local cursor,upper,seen=0,nil,{}
    for _page=1,501 do
        local page,reason=self.ledger:review_page(account,'pending',cursor,upper,100)
        if not page then return nil,reason end
        if type(page)~='table' or not C.array(page.rows,0,100) or not C.integer(page.upper_id,cursor,2^53-1)
            or upper and page.upper_id~=upper or type(page.has_more)~='boolean' then return nil,'invalid_page' end
        upper=page.upper_id;local candidates,blocked={},{}
        for _i,entry in ipairs(page.rows) do
            local row=entry.source
            if not C.row(row) or row.id<=cursor or row.id>upper or entry.state~='pending' or type(entry.conflict)~='boolean' then return nil,'invalid_page' end
            cursor=row.id;report.scanned=report.scanned+1
            if report.scanned>50000 then return nil,'ledger_full' end
            if not C.array(entry.blocked,0,30) then return nil,'invalid_page' end
            for _j,range in ipairs(entry.blocked) do
                if not C.array(range,2,2) or not C.integer(range[1],row.start_time,row.start_time+row.duration-1)
                    or not C.integer(range[2],range[1]+1,row.start_time+row.duration) then return nil,'invalid_page' end
            end
            if not C.verified(row,now) then report.unsupported=report.unsupported+row.duration
            elseif (not book_id or row.book_id==book_id) and same(row,selected) then
                candidates[#candidates+1]=row;blocked[row.id]=entry.blocked
            end
        end
        if #candidates>0 then
            local coverage,why=self.coverage:preview_individual(account,candidates)
            if not coverage then return nil,why end
            report.covered=report.covered+coverage.covered;report.untracked=report.untracked+coverage.unverified
            local available={parts={}}
            for _i,part in ipairs(coverage.parts) do
                local split=Coverage.subtract(part.start_time,part.duration,1,blocked[part.row_id])
                if not split then return nil,'invalid_page' end
                report.conflicting=report.conflicting+split.covered
                for _j,item in ipairs(split.parts) do item.row_id=part.row_id;available.parts[#available.parts+1]=item end
            end
            local next_group=C.select(candidates,available,now,book_id)
            if next_group then
                if not selected.book_id then
                    selected.book_id,selected.file_id,selected.book_version,selected.time_zone=
                        next_group.book_id,next_group.file_id,next_group.book_version,next_group.time_zone
                end
                local by_id={};for _i,row in ipairs(next_group.rows) do by_id[row.id]=row end
                for _i,part in ipairs(next_group.parts) do
                    if selected.seconds>=600 or #selected.parts>=100 then break end
                    local duration=math.min(part.duration,600-selected.seconds)
                    selected.parts[#selected.parts+1]={row_id=part.row_id,start_time=part.start_time,duration=duration}
                    selected.seconds=selected.seconds+duration
                    if not seen[part.row_id] then seen[part.row_id]=true;selected.rows[#selected.rows+1]=by_id[part.row_id] end
                end
            end
        end
        if not page.has_more or selected.seconds>=600 or #selected.parts>=100 then
            report.upper_id,report.last_id,report.scan_complete=upper,cursor,not page.has_more
            if selected.seconds==0 then return {selection=false,report=report} end
            table.sort(selected.parts,function(a,b) return a.start_time<b.start_time end)
            local complete=C.select(selected.rows,{parts=selected.parts},now,selected.book_id)
            return {selection=assert(complete),report=report}
        end
        if #page.rows==0 or page.last_id~=cursor then return nil,'invalid_page' end
    end
    return nil,'ledger_full'
end
return M

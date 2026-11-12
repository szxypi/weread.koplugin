package.path='./?.lua;./?/init.lua;'..package.path
local H=require('spec.helpers.annotation_test_store')
package.preload['lua-ljsqlite3/init']=function() return {open=H.connect} end
local Ledger=require('weread.lib.offline_time_store')
local Coverage=require('weread.lib.readtime_coverage')
local Queue=require('weread.lib.readtime_transfer_queue')
local Journal=require('weread.lib.readtime_transfer_store')
local C=require('weread.lib.readtime_transfer_contract')
local Json=require('json');local codec={json_encode=function(_s,x) return Json.encode(x) end,json_decode=function(_s,x) return Json.decode(x) end}
local checks=0;local function eq(a,b) checks=checks+1;assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local account=string.rep('a',20);local roots={}
local function fixture(rows,since)
    local root=os.tmpname()..'-queue';assert(os.execute('mkdir -p '..string.format('%q',root))==0);roots[#roots+1]=root
    local ledger=Ledger:new(root);assert(ledger:summary(account))
    local function append(values)
        assert(ledger:_access(account,function(db)
            for _i,row in ipairs(values) do
                local w=db:prepare([[INSERT INTO windows(book_id,stats_book,start_time,last_seen,time_zone,book_version,closed,file_id,version_source)
                    VALUES(?,1,?,?,?, ?,1,?,?)]])
                w:bind(row.book_id or '42',row.start_time,row.start_time+row.duration,row.time_zone or '+08:00',row.version or 7,
                    row.file_id or string.rep('f',64),row.origin or 'epub_snapshot'):step();w:close()
                local id=db:prepare('SELECT last_insert_rowid()');local window=tonumber(id:step()[1]);id:close()
                local s=db:prepare('INSERT INTO segments(window_id,start_time,duration,state) VALUES(?,?,?,?)')
                s:bind(window,row.start_time,row.duration,row.state or 'pending'):step();s:close()
            end
            return true
        end))
    end
    append(rows)
    local coverage=Coverage:new(root,function() return since or 100 end);assert(coverage:initialize())
    local queue=Queue:new{ledger=ledger,coverage=coverage,now=function() return 200000 end}
    return ledger,coverage,queue,append
end
-- Unsupported first pages cannot starve a verified later file-bound group.
local rows={}
for i=1,120 do rows[#rows+1]={start_time=100+i*61,duration=60,version=0,origin='unavailable',file_id=''} end
for i=121,140 do rows[#rows+1]={start_time=100+i*61,duration=60} end
local ledger,coverage,queue=fixture(rows);local before=ledger:summary(account)
local result=assert(queue:select(account));eq(result.selection.seconds,600);eq(#result.selection.rows,10)
eq(result.selection.rows[1].id,121);eq(result.report.scanned,140);eq(result.report.unsupported,7200)
eq(ledger:summary(account).pending,before.pending);eq(ledger:summary(account).in_flight,0)
local journal=Journal:new{ledger=ledger,coverage=coverage,codec=codec}
local record=assert(journal:begin(account,result.selection,{request_hash=string.rep('d',64)}));eq(ledger:summary(account).in_flight,600)
assert(journal:cancel_prepared(record));eq(ledger:summary(account).pending,before.pending)
-- One captured file/version/zone across page boundaries; no current-version rewrite.
rows={{start_time=100,duration=60,version=3}}
for i=2,105 do rows[#rows+1]={start_time=100+i*61,duration=60,book_id='43',version=9,file_id=string.rep('e',64)} end
rows[#rows+1]={start_time=100+106*61,duration=60,version=3}
queue=({fixture(rows)})[3]
result=assert(queue:select(account));eq(result.selection.seconds,120);eq(result.selection.book_id,'42');eq(result.selection.book_version,3)
eq(result.selection.file_id,string.rep('f',64));eq(#result.selection.rows,2);eq(result.report.scan_complete,true)
eq(assert(queue:select(account,'43')).selection.book_id,'43')
-- Ambiguous intersections are excluded precisely; unaffected portions remain selectable.
ledger,coverage,queue=fixture({{start_time=100,duration=60},{start_time=130,duration=60}})
local page=assert(ledger:review_page(account,'pending',0,nil,20));eq(#page.rows,2);eq(page.rows[1].blocked[1][1],130);eq(page.rows[1].blocked[1][2],160)
result=assert(queue:select(account));eq(result.selection.seconds,60);eq(#result.selection.parts,2)
eq(result.selection.parts[1].start_time,100);eq(result.selection.parts[1].duration,30);eq(result.selection.parts[2].start_time,160)
journal=Journal:new{ledger=ledger,coverage=coverage,codec=codec};record=assert(journal:begin(account,result.selection,{request_hash=string.rep('d',64)}))
eq(ledger:summary(account).in_flight,60);eq(ledger:summary(account).pending,60);assert(journal:cancel_prepared(record))
-- An overlapping online range is distinct from ambiguous remaining time.
assert(coverage:reserve(account,160,30));result=assert(queue:select(account));eq(result.selection.seconds,60);eq(result.report.covered,60)
-- Tracking floor, future/unknown versions and all-covered rows are preserved.
ledger,coverage,queue=fixture({{start_time=80,duration=60},{start_time=150,duration=20},{start_time=200001,duration=2}},100)
assert(coverage:reserve(account,170,20));result=assert(queue:select(account));eq(result.selection.seconds,40)
eq(result.report.untracked,20);eq(result.report.covered,20);eq(result.report.unsupported,2)
eq(ledger:summary(account).pending,82)
-- Lists keep a ceiling and cursor while fresh records are appended.
local paging={fixture({{start_time=100,duration=1},{start_time=102,duration=1},{start_time=104,duration=1}})}
local append;ledger,append=paging[1],paging[4]
page=assert(ledger:review_page(account,'pending',0,nil,2));eq(page.has_more,true);eq(page.upper_id,3);eq(page.last_id,2)
append({{start_time=106,duration=1}})
local last=assert(ledger:review_page(account,'pending',page.last_id,page.upper_id,2));eq(#last.rows,1);eq(last.has_more,false);eq(last.rows[1].source.id,3)
eq(#assert(ledger:review_page(account,'pending',0,nil,100)).rows,4)
eq(ledger:review_page(account,'arbitrary',0,nil,20),nil);eq(ledger:review_page(account,'pending',true,nil,20),nil)
eq(ledger:review_page(account,'pending',3,2,20),nil)
-- Unknown/in-flight records stay separate from covered and pending lists.
local categories={fixture({{start_time=100,duration=5,state='unknown'},{start_time=110,duration=6,state='in_flight'},
    {start_time=120,duration=7,state='covered'},{start_time=130,duration=8}})}
ledger,queue=categories[1],categories[3]
eq(#assert(ledger:review_page(account,'review')).rows,2);eq(#assert(ledger:review_page(account,'covered')).rows,1)
eq(assert(queue:select(account)).selection.seconds,8);eq(ledger:summary(account).unknown,5);eq(ledger:summary(account).covered,7)
-- Corruption outside the chosen page cannot evade indexed overlap checks.
local db=H.connect(ledger:path(account));db:exec('UPDATE segments SET duration=1000 WHERE id=1');db:close()
eq(ledger:review_page(account,'pending'),nil);eq(queue:select(account),nil);eq(ledger:summary(account),nil)
-- A changed source after planning is rejected before any ledger claim.
ledger,coverage,queue=fixture({{start_time=100,duration=60}});result=assert(queue:select(account))
db=H.connect(ledger:path(account));db:exec('UPDATE windows SET book_version=8');db:close()
journal=Journal:new{ledger=ledger,coverage=coverage,codec=codec};eq(journal:begin(account,result.selection,{request_hash=string.rep('d',64)}),nil)
eq(ledger:summary(account).pending,60);eq(queue:select('invalid'),nil)
-- Selection hashes still match the contract used by the transport gate.
result=assert(queue:select(account));eq(result.selection.rows_hash,C.digest(result.selection.rows));eq(result.selection.parts_hash,C.digest(result.selection.parts))
for _i,root in ipairs(roots) do os.execute('rm -rf '..string.format('%q',root)) end
print('readtime_transfer_queue_spec: '..checks..' checks')

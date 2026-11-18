-- Create a synthetic native capture database for exact restoration tests.
require('setupkoenv')
local json=require('json')
local function deny() error('synthetic_seed/network_disabled') end
package.loaded['socket.http']={request=deny};package.loaded['ssl.https']={request=deny}
local root,folder=assert(arg[1]),assert(arg[2]);package.path=root..'/?.lua;'..package.path
local plan=json.decode(assert(io.stdin:read('*a')))
local cb=arg[3]=='cb';assert(arg[3]==nil or cb)
assert(plan.owner=='900000' and plan.book_id==(cb and 'CB_Synthetic' or '900001') and plan.chapter_uid=='2')
local C=require('weread.lib.readtime_transfer_contract')
local Ledger=require('weread.lib.offline_time_store');local Coverage=require('weread.lib.readtime_coverage')
local account=require('weread.lib.native_position_contract').account_key(plan.owner)
local ledger=Ledger:new(folder);local coverage=Coverage:new(folder,function() return plan.start_time end)
assert(coverage:initialize()==plan.start_time)
local window=assert(ledger:begin(account,{book_id=plan.book_id,stats_book=1,start_time=plan.start_time,
    time_zone='+08:00',book_version=plan.book_version,file_id=plan.file_id,version_source='epub_snapshot'}))
local spans={};for index,row in ipairs(plan.rows) do spans[index]={page=tostring(index),start_time=row.start_time,duration=row.duration} end
assert(ledger:collect(account,window,spans,plan.ended_at,true).seconds==plan.seconds)
assert(C.digest(assert(ledger:pending(account)))==C.digest(plan.rows))
print('\nWEREAD_SYNTHETIC_BUNDLE_SEED=PASS')

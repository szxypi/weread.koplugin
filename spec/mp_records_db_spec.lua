package.path='./?.lua;'..package.path
local sqlite=require('spec.helpers.annotation_test_store')
local Crypto=require('weread.lib.crypto')
local Store=require('weread.lib.mp_records_db')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local unique=os.tmpname();os.remove(unique)
local account=Crypto.sha256_hex(unique):sub(1,20)
local store=assert(Store.new({data_dir='/tmp'},account,sqlite.connect))
local other=assert(Store.new({data_dir='/tmp'},Crypto.sha256_hex(unique..'other'):sub(1,20),sqlite.connect))
local key=string.rep('a',64)
local first='return { ["last_xpointer"]="/body/p.2", ["annotations"]={ [1]={ ["drawer"]="lighten", ["text"]="合成笔记", ["pos0"]="/body/p.1", ["pos1"]="/body/p.2" } } }'
local second='return { ["last_xpointer"]="/body/p.4" }'
local id=Store.id('primary',first)
expect(store:save(key,{{kind='primary',raw=first},{kind='backup',raw=second}}),'snapshots were not saved')
expect(store:get(key,id)==first,'raw snapshot readback differs')
expect(store:save(key,{{kind='primary',raw=first}}) and #store:list(key)==2,'exact duplicate created extra snapshot')
local rows=store:list(key);local found=false
for _i,row in ipairs(rows) do
    if row.id==id then found=row.valid and row.notes==1 and row.has_position and row.preview=='合成笔记' end
end
expect(found,'stored preview or position missing')
expect(other:get(key,id)==nil and #other:list(key)==0,'accounts shared recovery data')
expect(store:get(string.rep('b',64),id)==nil,'articles shared recovery data')
local sources={}
for _i,kind in ipairs({'beside','beside_backup','folder','folder_backup','legacy_beside','history','history_backup','compatibility'}) do
    sources[#sources+1]={kind=kind,raw=second}
end
expect(store:save(string.rep('b',64),sources) and #store:list(string.rep('b',64))==8,'native record source kinds could not be preserved together')
expect(Store.id('backup',first)~=id,'primary and backup source roles merged')
expect(not store:save(key,{[1]={kind='primary',raw=first},[3]={kind='backup',raw=second}}),'sparse batch was truncated')
expect(not store:save(key,{{kind='unknown',raw=first}}),'unrecognized snapshot source accepted')
expect(not Store.new({data_dir='/tmp'},'private-account') and not store:save('bad',{}),'invalid storage identity accepted')
local original_max=Store.MAX_RECORDS;Store.MAX_RECORDS=2
expect(not store:save(key,{{kind='live',raw=first}}) and #store:list(key)==2,'capacity failure changed saved history')
Store.MAX_RECORDS=original_max
local db=sqlite.connect(store.path)
db:exec([[CREATE TRIGGER reject_live BEFORE INSERT ON snapshots WHEN NEW.source_kind='live' BEGIN SELECT RAISE(FAIL,'synthetic write failure'); END]])
db:close()
local third='return { ["last_xpointer"]="/body/p.5" }'
expect(not store:save(key,{{kind='primary',raw=third},{kind='live',raw=third}}),'transaction failure was hidden')
expect(store:get(key,Store.id('primary',third))==nil and #store:list(key)==2,'partial snapshot batch committed')
db=sqlite.connect(store.path);db:exec('DROP TRIGGER reject_live')
local stmt=db:prepare('UPDATE snapshots SET raw=? WHERE article_key=? AND record_id=?')
stmt:reset():bind('return {}',key,id):step();stmt:close();db:close()
expect(store:get(key,id)==nil and store:list(key)==nil,'corrupted snapshot checksum accepted')
for _i,value in ipairs({store,other}) do for _j,suffix in ipairs({'','-journal','-wal','-shm'}) do os.remove(value.path..suffix) end end
sqlite.cleanup()
print('PASS: immutable record SQLite, account separation and atomic rollback ('..checks..' checks)')

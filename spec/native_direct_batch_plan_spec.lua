package.path='./?.lua;'..package.path
local helper=require('spec.helpers.annotation_test_store')
local Library=require('weread.lib.library_db')
local Plan=require('weread.lib.native_direct_batch_plan')

local vid='123'
local scope={vid=vid}
local path,other_path=os.tmpname(),os.tmpname()
local library=Library:new({get=function() return {user_vid=vid} end})
function library:databasePath() return vid=='123' and path or other_path end
function library:open()
    local db=helper.connect(self:databasePath())
    db:exec('CREATE TABLE IF NOT EXISTS profile_state (name TEXT PRIMARY KEY, payload TEXT)')
    return db
end
function library:openRead() return self:open() end
local catalog={book_id='42',version=1,reading_digest=string.rep('a',64),chapters={{},{},{}}}
local active=true
local function current() return active end
local plan=Plan:new(library,scope)
assert(not plan:read('42',current))
assert(not plan:begin(catalog,{first=1},nil,current),'partial bounds fell back to a wider range')
local initial=assert(plan:begin(catalog,{first=2,last=3},nil,current))
local reopened=Plan:new(library,scope)
local persisted=assert(reopened:read('42',current))
assert(persisted.revision==initial.revision)
local range=assert(reopened:range(persisted,catalog))
assert(range.first==2 and range.last==3)
catalog.reading_digest=string.rep('b',64)
assert(not reopened:range(persisted,catalog),'a changed catalog inherited the saved range')
assert(not reopened:begin(catalog,nil,nil,current),'an unobserved write replaced the saved plan')
local changed=assert(reopened:begin(catalog,{first=1,last=1},persisted,current))
assert(changed.revision~=persisted.revision)
assert(not reopened:remove('42',persisted,current),'late completion deleted a new download')
assert(not reopened:read('43',current),'a different book inherited the plan')
active=false
assert(not reopened:read('42',current) and not reopened:remove('42',changed,current))
active=true
vid='456'
assert(not reopened:read('42',current) and not reopened:remove('42',changed,current))
local other=Plan:new(library,{vid=vid})
assert(not other:read('42',current))
assert(other:begin(catalog,nil,nil,current))
vid='123'
assert(reopened:read('42',current).revision==changed.revision)
assert(reopened:remove('42',changed,current) and not reopened:read('42',current))
local db=library:open()
db:exec([[INSERT INTO profile_state VALUES ('eink_batch_v1:42','damaged')]])
db:close()
assert(not reopened:read('42',current),'a malformed plan became a resume offer')
os.remove(path);os.remove(other_path)
print('PASS: local chapter download plans survive reopen and protect book, account and newer ranges')

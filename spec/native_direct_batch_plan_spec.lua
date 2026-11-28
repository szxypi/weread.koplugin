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
catalog.book_id='43'
local listed=assert(reopened:begin(catalog,{first=2,last=2},nil,current))
assert(library:putProfileState('statistics',listed))
local records=assert(reopened:list(current))
assert(#records==1 and records[1].revision==listed.revision,'listing accepted damaged or unrelated rows')
local plain=Plan:new(library,scope,'standard')
local chapters={{chapterUid='11',chapterIdx=1},{chapterUid='12',chapterIdx=2}}
local epub=assert(Plan.standard_catalog('43',7,chapters))
assert(not plain:begin(epub,{first=2,last=2},nil,current),'an EPUB plan accepted a chapter range')
local saved=assert(plain:begin(epub,nil,nil,current))
local after_restart=Plan:new(library,scope,'standard')
assert(after_restart:read('43',current).revision==saved.revision and #assert(after_restart:list(current))==1)
assert(reopened:read('43',current).revision==listed.revision,'an EPUB plan overwrote a native range for the same book')
local reordered=assert(Plan.standard_catalog('43',7,{chapters[2],chapters[1]}))
assert(not plain:range(saved,reordered) and not plain:range(saved,Plan.standard_catalog('43',8,chapters)))
assert(plain:range(saved,Plan.standard_catalog('43',0,chapters)),'unknown version prevented independently checked staging')
local imported=assert(Plan.standard_catalog('CB_Fixture',0,chapters))
assert(plain:begin(imported,nil,nil,current) and not reopened:read('CB_Fixture',current))
assert(after_restart:remove('43',saved,current) and not plain:read('43',current) and reopened:read('43',current))
local selections=Plan:new(library,scope,'selected')
local third={chapterUid='19',chapterIdx=3}
local picked=assert(selections:begin(Plan.standard_catalog('43',7,{chapters[1],third}),nil,nil,current))
selections=Plan:new(library,scope,'selected')
local reference=assert(selections:list(current))[1]
assert(reference.count==2 and reference.revision==picked.revision and reference.selection==nil)
local fresh={chapters[1],chapters[2],third}
local subset,persisted_selection=selections:selectChapters('43',7,fresh,reference,current)
assert(subset and #subset==2 and subset[1]==chapters[1] and subset[2]==third)
assert(persisted_selection and persisted_selection.selection=='11,19')
assert(not selections:selectChapters('43',7,{third,chapters[2],chapters[1]},reference,current))
assert(not selections:selectChapters('43',8,fresh,reference,current))
assert(not selections:selectChapters('43',7,chapters,reference,current))
local replacement=assert(selections:begin(Plan.standard_catalog('43',7,{chapters[2]}),nil,picked,current))
assert(not selections:selectChapters('43',7,fresh,reference,current) and not selections:remove('43',reference,current))
assert(#assert(selections:list(current))==1 and selections:read('43',current).revision==replacement.revision)
assert(reopened:read('43',current).revision==listed.revision)
vid='456'
assert(not reopened:list(current) and not plain:list(current) and not selections:list(current)
    and #assert(other:list(current))==1,'listing exposed another account')
os.remove(path);os.remove(other_path)
print('PASS: local chapter download plans survive reopen and protect book, account and newer ranges')

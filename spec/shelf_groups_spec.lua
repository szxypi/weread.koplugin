package.path = "./?.lua;./?/init.lua;" .. package.path

local Groups = require("weread.lib.shelf_groups")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local books = {
    { bookId = "one", title = "One" },
    { bookId = "two", title = "Two" },
    { bookId = "three", title = "Three" },
}
local groups = Groups.list({
    { archiveId = 7, name = "Reading", bookIds = { "two", "one", "two", "missing" } },
    { name = "", bookIds = { "three" } },
}, books, "Unnamed group")

expect(#groups == 2, "user-defined groups were dropped")
expect(groups[1].label == "Reading" and #groups[1].books == 2,
    "group did not retain known members in user order")
expect(groups[1].books[1].bookId == "two" and groups[1].books[2].bookId == "one",
    "group order or duplicate handling is wrong")
expect(groups[2].label == "Unnamed group" and groups[2].books[1].bookId == "three",
    "blank group name did not retain its book")
expect(groups[1].key == "archive:7" and Groups.find(groups, "archive:7") == groups[1]
        and Groups.find(groups, "archive:99") == nil,
    "group selection lookup is not stable")

local projected = Groups.list({
    { archiveId = 8, name = "Reading", bookIds = { "one" } },
    { archiveId = 9, name = "公众号", bookIds = { "MP_WXS_123" } },
    { archiveId = 10, name = "Empty", bookIds = {} },
}, books, "Unnamed group", "Uncategorized")
expect(#projected == 3 and projected[1].label == "Reading"
        and projected[2].label == "Empty" and projected[3].label == "Uncategorized",
    "public-account archive or ungrouped books were projected incorrectly")
expect(#projected[3].books == 2 and projected[3].books[1].bookId == "two"
        and projected[3].books[2].bookId == "three",
    "ungrouped books were not retained in shelf order")

local reordered = Groups.list({
    { archiveId = 10, name = "Empty", bookIds = {} },
    { archiveId = 7, name = "Reading", bookIds = { "one" } },
}, books, "Unnamed group", "Uncategorized")
expect(Groups.find(reordered, "archive:7").label == "Reading",
    "server group identifier did not survive a reordered shelf response")

expect(#Groups.list({}, books, "Unnamed group", "Uncategorized") == 0,
    "an ungrouped shelf added a duplicate all-books choice")
local unavailable = Groups.list({
    {archiveId=11,name='Unavailable books',bookIds={'missing'}},
    {archiveId=12,name='Mixed',bookIds={'MP_WXS_123','missing'}},
    {archiveId=13,name='Accounts',bookIds={'MP_WXS_123'}},
},books)
expect(#unavailable==3 and #unavailable[1].books==0 and #unavailable[2].books==0
    and unavailable[3].key=='__ungrouped__','unavailable regular references hid user groups')

local overlap=Groups.list({
    {archiveId=1,name='A',bookIds={'two','one'}},
    {archiveId=2,name='B',bookIds={'three','two'}},
    {archiveId=3,name='Empty',bookIds={}},
},books)
local selection,state=Groups.selected(overlap,{'archive:2','archive:1'},books)
expect(state=='selected' and #selection==3 and selection[1]==books[1] and selection[2]==books[2]
    and selection[3]==books[3],'multi-group union lost shelf order or duplicated a book')
selection,state=Groups.selected(overlap,{'archive:3'},books)
expect(state=='selected' and #selection==0,'selected empty group fell back to all')
selection,state=Groups.selected(overlap,{'archive:1','archive:missing'},books)
expect(selection==nil and state=='unavailable','incomplete snapshot narrowed the shelf')
local ambiguous=Groups.list({{archiveId=1,name='A',bookIds={'one'}},{archiveId=1,name='B',bookIds={'two'}}},books)
expect(not Groups.unique(ambiguous,'archive:1') and select(2,Groups.selected(ambiguous,{'archive:1'},books))=='unavailable',
    'duplicate archive identifier was treated as unique')
local same_name=Groups.list({{archiveId=1,name='Reading',bookIds={'one'}},{archiveId=2,name='Reading',bookIds={'two'}}},books)
expect(Groups.unique(same_name,'archive:1').books[1]==books[1] and Groups.unique(same_name,'archive:2').books[1]==books[2],
    'groups with the same name but distinct identifiers were conflated')
local normalized=Groups.normalize({'archive:2','archive:1'})
expect(normalized[1]=='archive:1' and normalized[2]=='archive:2','stored selection was not canonical')
expect(not Groups.normalize({'archive:1','archive:1'}) and not Groups.normalize({[1]='archive:1',[3]='archive:2'})
    and not Groups.normalize({'bad\nkey'}),'invalid persisted selection accepted')

print(("shelf_groups_spec: %d checks"):format(checks))

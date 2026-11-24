package.path='./?.lua;'..package.path
local Model=require('weread.lib.local_shelf_groups')
local Groups=require('weread.lib.shelf_groups')
local n=0
local function expect(value) n=n+1;assert(value,'local groups check '..n) end
local empty=Model.empty();expect(Model.valid(empty))
local cloud=Groups.list({{archiveId=7,name='云端组',bookIds={'42','missing','MP_WXS_1'}}},{{bookId='42'}})[1]
local copied=assert(Model.copy_cloud(empty,cloud,'本机副本'))
expect(#empty.groups==0 and copied.groups[1].name=='本机副本' and #copied.groups[1].books==2
    and copied.groups[1].books[1]=='42' and copied.groups[1].books[2]=='missing')
cloud.member_ids[1]='changed';expect(copied.groups[1].books[1]=='42')
expect(not Model.copy_cloud(copied,cloud,'本机副本') and not Model.copy_cloud(empty,{member_ids={'42','42'}},'bad')
    and not Model.copy_cloud(empty,{member_ids={'MP_WXS_1'}},'bad') and not Model.copy_cloud(empty,{},'bad'))
local imported_shelf={{bookId='42',title='普通书'},{bookId='CB_SyntheticGroup',title='导入书'}}
local imported_cloud=Groups.list({{archiveId=8,name='混合组',bookIds={'42','CB_SyntheticGroup','CB_Missing','MP_WXS_1'}}},imported_shelf)[1]
local imported_copy=assert(Model.copy_cloud(empty,imported_cloud,'混合副本'))
expect(#imported_copy.groups[1].books==3 and imported_copy.groups[1].books[2]=='CB_SyntheticGroup'
    and imported_copy.groups[1].books[3]=='CB_Missing')
local imported_project=assert(Model.project(imported_copy,imported_shelf,function(label)return label end))
expect(#imported_project[1].books==2 and imported_project[1].incomplete)
local imported_removed=assert(Model.assign(imported_copy,'CB_SyntheticGroup',{}))
expect(#imported_removed.groups[1].books==2 and imported_removed.groups[1].books[2]=='CB_Missing')
local first=assert(Model.change(empty,{kind='create',name='  已读  '}))
expect(#empty.groups==0 and first.groups[1].name=='已读' and first.groups[1].id==1)
expect(not Model.change(first,{kind='create',name='已读'}))
expect(not Model.change(first,{kind='create',name='  '}))
expect(not Model.change(first,{kind='create',name='　 '}))
expect(not Model.change(first,{kind='create',name='　已读 '}))
expect(not Model.change(first,{kind='rename',id=2,name='other'}))
local renamed=assert(Model.change(first,{kind='rename',id=1,name='待回顾'}))
expect(first.groups[1].name=='已读' and renamed.groups[1].name=='待回顾')
local values={'42','9007199254740993','missing'}
local saved=assert(Model.change(renamed,{kind='books',id=1,books=values}))
values[1]='changed';expect(saved.groups[1].books[1]=='42')
expect(not Model.change(saved,{kind='books',id=1,books={'42','42'}}))
expect(not Model.change(saved,{kind='books',id=1,books={'42',42}}))
local books={{bookId='42',title='A'},{bookId='9007199254740993',title='B'},{bookId='43',title='C'}}
local projected=assert(Model.project(saved,books,function(label) return 'Local · '..label end))
expect(#projected==1 and projected[1].key=='local:1' and projected[1].incomplete and #projected[1].books==2)
local selected=assert(Groups.selected(projected,{'local:1'},books))
expect(#selected==2 and selected[1].bookId=='42' and selected[2].bookId=='9007199254740993')
local second=assert(Model.change(saved,{kind='create',name='稍后看'}))
local assigned=assert(Model.assign(second,'43',{1,2}))
expect(#assigned.groups[1].books==4 and assigned.groups[1].books[3]=='missing' and assigned.groups[1].books[4]=='43')
expect(#assigned.groups[2].books==1 and assigned.groups[2].books[1]=='43' and #second.groups[2].books==0)
local moved=assert(Model.assign(assigned,'43',{2}))
expect(#moved.groups[1].books==3 and moved.groups[1].books[3]=='missing' and moved.groups[2].books[1]=='43')
expect(not Model.assign(moved,'43',{2,2}) and not Model.assign(moved,'43',{99}) and not Model.assign(moved,43,{2}))
local removed=assert(Model.assign(moved,'43',{}))
expect(#removed.groups[2].books==0 and #removed.groups[1].books==3)
local deleted=assert(Model.change(saved,{kind='delete',id=1}))
local next_group=assert(Model.change(deleted,{kind='create',name='新的'}))
expect(#deleted.groups==0 and next_group.groups[1].id==2)
local bad=Model.empty();bad.groups={{id=1,name='bad',books={}}}
expect(not Model.valid(bad) and not Model.project(bad,books,function(v)return v end))
bad=Model.empty();bad.extra=true;expect(not Model.valid(bad))
bad=Model.empty();bad.groups={[2]={id=1,name='bad',books={}}};expect(not Model.valid(bad))
print('local_shelf_groups_spec: '..n..' checks')

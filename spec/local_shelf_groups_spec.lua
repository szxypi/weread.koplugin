package.path='./?.lua;'..package.path
local Model=require('weread.lib.local_shelf_groups')
local Groups=require('weread.lib.shelf_groups')
local n=0
local function expect(value) n=n+1;assert(value,'local groups check '..n) end
local empty=Model.empty();expect(Model.valid(empty))
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
local deleted=assert(Model.change(saved,{kind='delete',id=1}))
local next_group=assert(Model.change(deleted,{kind='create',name='新的'}))
expect(#deleted.groups==0 and next_group.groups[1].id==2)
local bad=Model.empty();bad.groups={{id=1,name='bad',books={}}}
expect(not Model.valid(bad) and not Model.project(bad,books,function(v)return v end))
bad=Model.empty();bad.extra=true;expect(not Model.valid(bad))
bad=Model.empty();bad.groups={[2]={id=1,name='bad',books={}}};expect(not Model.valid(bad))
print('local_shelf_groups_spec: '..n..' checks')

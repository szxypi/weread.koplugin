package.path='./?.lua;'..package.path
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
local Context=require('weread.lib.excerpt_context')
local calls=0
local host={settings={get_book=function(_,id)
    calls=calls+1;assert(id=='42');return {book_id='43',title='Wrong cached book',author='Wrong'}
end},library_db={getBook=function(_,id)
    calls=calls+1;assert(id=='42');return {bookId='42',title='Correct title',authors={'First','Second'}}
end}}
local value=assert(Context.make(host,'42','  Selected text  ',{title='Reader title',author='Reader author'}))
assert(value.text=='Selected text' and value.book_title=='Correct title' and value.book_author=='First · Second')
assert(calls==2,'metadata was not read through the selected book')
host.library_db.getBook=function() return {bookId=100000000000000,title='Ambiguous number'} end
value=assert(Context.make(host,'42','text',{title='Reader title',author='Reader author'}))
assert(value.book_title=='Reader title' and value.book_author=='Reader author','foreign cache supplied metadata')
assert(not Context.make(host,'42','\255') and not Context.make(host,'42',string.rep('x',4097)))
assert(not Context.make(host,'42','\0') and not Context.make(host,'','text'))
print('PASS: excerpt context selection and book identity')

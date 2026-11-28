package.path='./?.lua;'..package.path
package.preload['ffi/utf8proc']=function() return {lowercase=function(value)
    return value=='É' and 'é' or value
end} end
package.preload['weread.lib.unicode_normalize']=function() error('synthetic unavailable library') end
local Unicode=require('weread.lib.unicode_search')
assert(Unicode.available() and not Unicode.canonical_available())
local result=assert(Unicode.build('École',1,'éCOLE'))
assert(result.text==result.needle and select(3,result.locate(1)))
print('unicode_normalization_fallback_spec: existing casefold works when optional canonical library is unavailable')

package.path='./?.lua;'..package.path
local Model=require('weread.lib.translation')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function analyze(body,index)
    return assert(Model.analyze('<html><head><title>Synthetic</title></head><body>'..body..'</body></html>','chapter',index or 1))
end
local function book(chapters)
    local out={blocks=0,chapters=chapters}
    for _,chapter in ipairs(chapters) do out.blocks=out.blocks+chapter.blocks end
    return out
end
local a=analyze('<p id="pair">Original</p><p id="pair" class="wr-translation">译文</p>')
expect(a.blocks==1 and #a.pairs==1 and a.pairs[1].kind=='id','matching ID siblings not paired')
local b=analyze('<p>Original <em>text</em></p> \n <p class="wr-translation">译文</p>',2)
expect(b.blocks==1 and #b.pairs==1 and b.pairs[1].kind=='adjacent','id-less actual chapter representation not paired')
local profile=book({a,b})
local css=assert(Model.css(profile,'translation'))
expect(css:find('DocFragment:nth-of-type(1) body #pair',1,true) and css:find('DocFragment:nth-of-type(2) body > p:nth-of-type(1)',1,true),
    'CSS did not scope shared IDs or path selectors to their native fragment')
expect(Model.css(profile,'original'):find('.wr-translation { display: none',1,true),'original view did not hide translation')
expect(Model.css(profile,'bilingual',120):find('font-size: 120%',1,true),'bilingual font scale missing')
expect(Model.translation_only_status(profile).available and Model.translation_only_status(profile).unpaired==0,'complete pairing status wrong')
for _,body in ipairs({
    '<p id="a">Original</p><p id="b" class="wr-translation">译文</p>',
    '<p id="pair">Original</p><p id="pair" class="wr-translation">译文</p><p id="pair">Duplicate</p>',
    '<p>Original</p>intervening text<p class="wr-translation">译文</p>',
    '<p>Original<img src="synthetic.png"/></p><p class="wr-translation">译文</p>',
    '<p>Original<a href="#note">footnote</a></p><p class="wr-translation">译文</p>',
    '<p id="pair">Original<img src="synthetic.png"/></p><p id="pair" class="wr-translation">译文</p>',
    '<div>Original</div><div class="wr-translation">译文</div>',
    '<span>Original</span><span class="wr-translation">译文</span>',
    '<div><p>Original</p><p class="wr-translation">译文</p></div><div class="wr-translation">wrapper</div>',
}) do
    local row=analyze(body)
    if body:find('wrapper',1,true) then expect(#row.pairs==1,'container was paired across translated descendants')
    else expect(#row.pairs==0 and Model.css(book({row}),'translation')==nil,'unverified source hidden') end
end
local mixed=analyze('<p id="pair">Original</p><p id="pair" class="wr-translation">译文</p><p id="only">Keep</p><p id="other" class="wr-translation">Another</p>')
local status=Model.translation_only_status(book({mixed}))
expect(status.available and status.reason=='partial' and status.unpaired==1,'unpaired translations disabled verified pairs')
expect(not Model.css(book({mixed}),'translation'):find('#only',1,true),'unpaired original hidden')
local raw=analyze('<style>.sample:before { content:"<p>"; }</style><p>Original</p><p class="wr-translation">译文 &amp; &#x4e2d;</p>')
expect(raw.blocks==1 and #raw.pairs==1,'raw style or text entities broke parsing')
local invalid,reason=Model.analyze('<html><body><p>missing close','chapter',1)
expect(not invalid and reason=='incomplete_document','incomplete document guessed a pair')
invalid,reason=Model.analyze(string.rep('x',Model.MAX_HTML_BYTES+1),'chapter',1)
expect(not invalid and reason=='html_limit','HTML bound ignored')
invalid,reason=Model.analyze('<body/>','chapter',1.5)
expect(not invalid and reason=='fragment_identity','fractional fragment accepted')
expect(Model.normalize_mode('unexpected')=='original' and Model.normalize_font_scale(0/0)==100
    and Model.normalize_font_scale(1000)==180 and Model.normalize_font_scale(-5)==80,'preference bounds wrong')
local xp='/body/DocFragment[1]/body/p[1]/text().3'
expect(Model.remap_xpointer(profile,xp,'translation')=='/body/DocFragment[1]/body/p[2]','original did not map to paired translation start')
expect(Model.remap_xpointer(profile,'/body/DocFragment/body/p[2].0','original')=='/body/DocFragment[1]/body/p[1]',
    'first-fragment abbreviated pointer or paragraph offset not restored')
expect(Model.remap_xpointer(profile,xp,'bilingual')==nil,'bilingual view moved the current anchor')
expect(Model.remap_xpointer(profile,'/body/DocFragment[1]/body/p[10]/text().0','translation')==nil,'paragraph prefix collision mapped wrong content')
expect(Model.remap_xpointer(profile,'/body/DocFragment[3]/body/p[1]/text().0','translation')==nil,'pointer mapped across chapter identity')
print('PASS: translation display model ('..checks..' checks)')

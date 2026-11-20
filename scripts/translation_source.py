"""Admission for English prose protocol samples, not a universal language detector."""
import re
from translation_result import original_text,OriginalText


def structural_title(title):
    if title is None:return None
    if not isinstance(title,str) or len(title.encode())>4096 or '\0' in title:raise ValueError('translation_generation/chapter_title')
    value=' '.join(title.split()).casefold()
    if '版权' in ''.join(value.split()) or re.search(r'\bcopyright\b',value):return 'copyright'
    if re.fullmatch(r'(?:table of )?contents',value) or ''.join(value.split())=='目录':return 'contents'
    if value in ('cover','front cover','back cover','封面','封底'):return 'cover'
    if value in ('title page','扉页','书名页'):return 'title_page'
    return None


def chapter_title(sample,uid):
    source=sample.get('source')
    if not isinstance(source,dict):return None
    rows=source.get('data',[])
    for record in rows:
        if isinstance(record,dict) and str(record.get('bookId'))==sample['book_id']:
            for row in record.get('updated',[]):
                if isinstance(row,dict) and str(row.get('chapterUid'))==str(uid):return row.get('title')
    return None


def admit_source(source,title=None):
    if structural_title(title):raise ValueError('translation_generation/structural_source')
    text=original_text(source)
    if re.search(r'<a(?:\s|>)',source,re.I):
        class Links(OriginalText):
            def __init__(self):super().__init__();self.links=0;self.link_text=[]
            def handle_starttag(self,tag,attrs):
                super().handle_starttag(tag,attrs)
                if tag=='a' and self.stack[-1][1] is None:self.links+=1
            def handle_data(self,value):
                before=len(self.text);super().handle_data(value)
                if len(self.text)>before and any(row[0]=='a' for row in self.stack):self.link_text.append(value)
        links=Links();links.feed(source);links.close()
        anchored=len(re.sub(r'\s+',' ',''.join(links.link_text)).strip())
        if links.links>=5 and anchored*5>=len(text)*3:raise ValueError('translation_generation/structural_source')
    letters=sum(c.isalpha() for c in text);ascii_letters=sum(c.isascii() and c.isalpha() for c in text)
    words=len(re.findall(r"[A-Za-z]+(?:['’-][A-Za-z]+)*",text))
    if ascii_letters<100 or words<40 or ascii_letters*5<letters*4:raise ValueError('translation_generation/not_english_prose')
    return dict(english_prose_sample=True)

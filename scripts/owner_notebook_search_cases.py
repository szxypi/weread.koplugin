"""Choose bounded independent title/author/ID notebook search expectations."""
import re
from verify_owner_shelf_search_ui import matches


def prepare(snapshot):
    if not isinstance(snapshot,dict) or not isinstance(snapshot.get('books'),list):raise ValueError('notebook_search/input')
    books=snapshot['books']
    choices=[book for book in books if isinstance(book,dict) and all(isinstance(book.get(key),str)
        and re.fullmatch(r'[\u4e00-\u9fffa-zA-Z0-9]{2,20}',book[key]) for key in ('title','author'))]
    if not choices:raise ValueError('notebook_search/selection')
    book=choices[0]
    queries=[book['title']+' '+book['author'],book['bookId']+' '+book['author'],
             'KOReaderNoSuchNotebook0123456789']
    cases=[dict(query=query,expected=[row['bookId'] for row in books if matches(row,query)]) for query in queries]
    if any(book['bookId'] not in case['expected'] for case in cases[:2]) or cases[2]['expected']:
        raise ValueError('notebook_search/expected')
    return cases

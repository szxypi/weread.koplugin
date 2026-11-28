"""Independent, bounded, credential-free check of a single chapter image."""
import hashlib
from html.parser import HTMLParser
import re
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener

from verify_eink_login import NoRedirect

SUFFIXES = ('qq.com', 'qpic.cn', 'qlogo.cn', 'weixin.qq.com', 'myqcloud.com', 'qcloud.com')
MAX_IMAGE = 8 * 1024 * 1024


class ImageRefs(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.urls = []

    def handle_starttag(self, tag, attrs):
        if tag == 'img':
            self.urls.extend(value for name, value in attrs if name == 'src' and value
                             and value.lower().startswith(('https://', '//')))


class SearchText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.body = False
        self.hidden = False
        self.matches = []

    def handle_starttag(self, tag, _attrs):
        if tag == 'body':
            self.body = True
        if tag in ('script', 'style'):
            self.hidden = True

    def handle_endtag(self, tag):
        if tag == 'body':
            self.body = False
        if tag in ('script', 'style'):
            self.hidden = False

    def handle_data(self, text):
        if self.body and not self.hidden:
            self.matches.extend(re.findall(r'[\u4e00-\u9fff]{6,24}|[A-Za-z]{8,24}', text))


def search_token(body):
    if not isinstance(body, bytes) or not 0 < len(body) <= 8 * 1024 * 1024:
        raise ValueError('remote_reference/body')
    parser = SearchText()
    parser.feed(body.decode('utf8'))
    if not parser.matches:
        raise ValueError('remote_reference/no_search_token')
    return parser.matches[0]


def image_url(body):
    if not isinstance(body, bytes) or not 0 < len(body) <= 8 * 1024 * 1024:
        raise ValueError('remote_reference/body')
    parser = ImageRefs()
    parser.feed(body.decode('utf8'))
    refs = list(dict.fromkeys(parser.urls))
    if len(refs) != 1:
        raise ValueError('remote_reference/count')
    url = 'https:' + refs[0] if refs[0].startswith('//') else refs[0]
    parsed = urlsplit(url)
    host = (parsed.hostname or '').lower()
    if (parsed.scheme.lower() != 'https' or parsed.username or parsed.password or parsed.fragment
            or parsed.port not in (None, 443) or not any(host == suffix or host.endswith('.' + suffix) for suffix in SUFFIXES)
            or any(c.isspace() or ord(c) < 33 or c == '\\' for c in url) or len(url) > 4096):
        raise ValueError('remote_reference/host')
    return url


def digest(body, opener=None):
    url = image_url(body)
    request = Request(url, headers={'User-Agent': 'WeRead/2.1.2', 'Referer': 'https://weread.qq.com/', 'Accept': 'image/*'})
    try:
        with (opener or build_opener(NoRedirect())).open(request, timeout=20) as response:
            if response.status != 200:
                raise ValueError('remote_reference/http')
            data = response.read(MAX_IMAGE + 1)
    except HTTPError as exc:
        exc.close()
        raise ValueError('remote_reference/http') from None
    except (URLError, OSError, TimeoutError):
        raise ValueError('remote_reference/network') from None
    if not 0 < len(data) <= MAX_IMAGE:
        raise ValueError('remote_reference/size')
    if not (data.startswith((b'\x89PNG\r\n\x1a\n', b'\xff\xd8\xff', b'GIF87a', b'GIF89a'))
            or data.startswith(b'RIFF') and data[8:12] == b'WEBP'):
        raise ValueError('remote_reference/image')
    return hashlib.sha256(data).hexdigest()

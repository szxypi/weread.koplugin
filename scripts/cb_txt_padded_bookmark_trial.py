"""A TXT bookmark after a non-BMP scalar on a short synthetic fixture."""
from cb_txt_highlight_trial import BODY as BASE,TEXT
from cb_txt_bookmark_trial import Intent,prepare

# Empty lines supply scrollable native layout without a large upload; this
# remains comfortably below the fixed upload plan's 1024-byte limit.
BODY=BASE+b'\n'*120

"""Local original-TXT UTF-16 coordinates, independent of cloud wire units.

Literal tags/entities, BOM and line endings retain their raw widths. Display
whitespace is removed only for matching; no HTML parser touches the TXT source.
"""
import json
import subprocess

from verify_source_coordinates import CoordinateError, SourceText, boundaries

BASIS = 'raw_txt_utf16'


class PlainSource:
    def __init__(self, raw):
        self.raw, self.offsets = boundaries(raw)
        if not raw or any(ord(char) < 32 and char not in '\t\r\n' for char in raw):
            raise CoordinateError('txt: invalid source')
        self.characters = list(raw)
        self.starts, self.ends = self.offsets[:-1], self.offsets[1:]
        self.visible = [i for i, char in enumerate(raw) if not char.isspace()]
        self.flat = ''.join(raw[i] for i in self.visible)

    locate = SourceText.locate

    def locate_point(self, text, point_offset):
        clean = ''.join(char for char in text if not char.isspace())
        if type(point_offset) is not int or not 0 <= point_offset <= len(clean):
            raise CoordinateError('txt: invalid point')
        _start, end = self.locate(clean)
        first = self.flat.index(clean)
        return end if point_offset == len(clean) else self.starts[self.visible[first + point_offset]]


def sample_queries(model):
    queries = []
    for at in sorted({0, max(0, len(model.flat)//2 - 12), max(0, len(model.flat) - 24)}):
        for width in (24, 48, 96, 192):
            quote = model.flat[at:at + width]
            try:
                model.locate(quote)
            except CoordinateError:
                continue
            if quote not in queries:
                queries.append(quote)
            break
    if not queries:
        raise CoordinateError('txt: no unique context')
    return queries


def verify_sample(raw, lua_command=None):
    model = PlainSource(raw)
    queries = sample_queries(model)
    positions = [dict(co=model.locate(q)[0], end_co=model.locate(q)[1]) for q in queries]
    points = [[dict(point_offset=n, co=model.locate_point(q, n)) for n in (0, len(q)//2, len(q))] for q in queries]
    for quote, expected in zip(queries, positions):
        if model.locate_point(quote, 0) != expected['co'] or model.locate_point(quote, len(quote)) != expected['end_co']:
            raise CoordinateError('txt: model mismatch')
    result = dict(txt_local_coordinate_model_verified=True, txt_coordinate_queries=len(queries),
                  txt_coordinate_basis=BASIS, cloud_coordinate_semantics_verified=False,
                  precision_wire_sync_enabled=False)
    if lua_command:
        payload = dict(sources=[dict(html=raw, format='web_txt', queries=queries, target_co=positions[0]['co'])])
        try:
            child = subprocess.run(lua_command, input=json.dumps(payload, ensure_ascii=False), text=True,
                                   capture_output=True, timeout=60)
            if child.returncode or len(child.stdout.encode()) > 16*1024*1024:
                raise CoordinateError('txt: lua comparison unavailable')
            maps = json.loads(child.stdout)['maps']
            if not isinstance(maps, list) or len(maps) != 1:
                raise CoordinateError('txt: lua comparison invalid')
            actual = maps[0]
            if (actual.get('segments') != [[0, raw]] or actual.get('flat') != model.flat
                    or actual.get('positions') != positions or actual.get('scalar_positions') != points
                    or actual.get('basis') != BASIS):
                raise CoordinateError('txt: lua model mismatch')
            anchor = actual.get('target_anchor')
            if (not isinstance(anchor, dict) or anchor.get('basis') != BASIS
                    or anchor.get('point_unit') != 'unicode_scalars' or anchor.get('co') != positions[0]['co']
                    or model.locate_point(anchor.get('text', ''), anchor.get('point_offset')) != anchor['co']):
                raise CoordinateError('txt: lua target mismatch')
        except CoordinateError:
            raise
        except Exception:
            raise CoordinateError('txt: lua comparison unavailable') from None
        result.update(txt_lua_coordinate_model_verified=True, txt_lua_scalar_points=sum(map(len, points)),
                      txt_lua_target_roundtrip=True)
    return result

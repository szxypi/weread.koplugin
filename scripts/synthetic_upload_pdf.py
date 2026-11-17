"""Small deterministic, self-authored two-page PDF for upload validation."""

TEXT = 'Synthetic PDF page one confirms that imported content can be read.'
SECOND = 'Synthetic PDF page two confirms that separate pages are retained.'


def build():
    def stream(value):
        data = ('BT /F1 14 Tf 72 720 Td (' + value + ') Tj ET\n').encode('ascii')
        return b'<< /Length %d >>\nstream\n' % len(data) + data + b'endstream'

    objects = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>',
        b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
        stream(TEXT), stream(SECOND),
    ]
    output = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for index, body in enumerate(objects, 1):
        offsets.append(len(output))
        output.extend(('%d 0 obj\n' % index).encode() + body + b'\nendobj\n')
    xref = len(output)
    output.extend(('xref\n0 %d\n' % len(offsets)).encode())
    output.extend(b'0000000000 65535 f \n')
    for offset in offsets[1:]:
        output.extend(('%010d 00000 n \n' % offset).encode())
    output.extend(('trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(offsets), xref)).encode())
    return bytes(output)

"""Deterministic self-authored two-page PDF with text, columns and an embedded image."""
import zlib


def build():
    W,H=64,64
    pixels=bytes(c for y in range(H) for x in range(W) for c in ((245,245,245) if (x//8+y//8)%2 else (20,75,180)))
    image=zlib.compress(pixels,9)
    def stream(data,attrs=b''):
        return b'<< /Length %d %s >>\nstream\n' % (len(data),attrs)+data+b'\nendstream'
    def line(x,y,text,size=12):
        return f'BT /F1 {size} Tf {x} {y} Td ({text}) Tj ET\n'.encode('ascii')
    page1=b''.join((line(48,750,'Mixed PDF fixture: page one',16),line(48,714,'LEFT COLUMN START'),line(48,694,'Left column second sentence.'),line(320,714,'RIGHT COLUMN START'),line(320,694,'Right column second sentence.'),line(48,610,'Illustration follows:'),b'q 160 0 0 160 48 425 cm /Im1 Do Q\n',line(48,405,'IMAGE CAPTION: checkerboard image.'),line(48,360,'Page one trailing paragraph.')))
    page2=b''.join((line(48,750,'Mixed PDF fixture: page two',16),line(48,714,'Page two first paragraph.'),b'q 96 0 0 96 320 570 cm /Im1 Do Q\n',line(320,550,'SECOND IMAGE CAPTION'),line(48,500,'Page two final paragraph.')))
    objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 8 0 R >> >> /Contents 6 0 R >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 8 0 R >> >> /Contents 7 0 R >>',b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',stream(page1),stream(page2),stream(image,b'/Type /XObject /Subtype /Image /Width 64 /Height 64 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode')]
    out=bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n');offsets=[0]
    for i,obj in enumerate(objects,1):
        offsets.append(len(out));out.extend(f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n')
    xref=len(out);out.extend(f'xref\n0 {len(offsets)}\n'.encode()+b'0000000000 65535 f \n')
    for offset in offsets[1:]:out.extend(f'{offset:010d} 00000 n \n'.encode())
    out.extend(f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    return bytes(out)

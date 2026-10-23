# A book with no fonts of its own, mixing English and Chinese paragraphs:
# the case where every device falls back to its own system font. Some Chinese
# paragraphs run longer than a page.
#
# Chapters also end the ways converted books do, leaving pages with nothing
# on them (issue #22): a run of empty paragraphs, and a page break before an
# empty paragraph. The book itself ends in blank pages, and one chapter holds
# a picture on a page of its own, with no text on it, and one holds lines too
# long for the column. One chapter is wrapped in a box that clips its
# overflow, and every chapter's last paragraph is marked so the check can
# tell it was shown.
import sys
import struct, zipfile, zlib, random
random.seed(7)
words = "the book pages were scanned and converted to EPUB format automatically this process relies on optical character recognition and is somewhat susceptible to errors weird characters non-words incorrect guesses at structure numbering internationalization extraordinary".split()
cjk = "這本書是由網際網路檔案館以電子書格式製作的書頁經過掃描並自動轉換為電子書格式，這個過程依賴光學字元辨識，因此容易出錯。「引號」與（括號）、標點！？"
def para(i):
    # Longer than a page: a page that starts inside it has no space to start
    # a "word" at (issue #21).
    if i % 9 == 8:
        return "".join(random.choice(cjk) for _ in range(random.randint(900, 1600)))
    if i % 3 == 2:
        return "".join(random.choice(cjk) for _ in range(random.randint(60, 220)))
    return " ".join(random.choice(words) for _ in range(random.randint(30, 120))).capitalize() + "."
def png(width, height):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\0" + bytes([(x * 7 + y * 3) % 256 for x in range(width)]) for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
picture = '<div style="page-break-before: always; break-after: column"><img src="plate.png" alt="" style="width: 100%"/></div>'
empty_paragraphs = "".join("<p>&#160;</p>" for _ in range(40))
endings = [
    empty_paragraphs,
    '<div style="page-break-before: always"><p>&#160;</p></div>',
    empty_paragraphs,
]
# Lines that cannot break where the column ends (GH-52): a URL in Chinese
# text, which the shared stylesheet must wrap, and the same paragraph kept
# from breaking the way a book's own !important style can. Its URL line
# spills into the next page's strip with the rest of the paragraph on the
# lines below it, which is what named the next page by a character of this
# one. Repeated, so one of them lands at the foot of a page.
url = "可以先尝试通过在线网站CloudFlareWatch（http://www.crimeflare.us/cfs.xhtml#box-and-a-much-longer-anchor-that-cannot-break）对CloudFlare客户网站进行真实IP查询，结果如图1-12所示，" + cjk * 2
def extra(c, i):
    if c == 2 and i == 3:
        return picture
    if c == 1 and i % 3 == 0:
        return f'<p>{url}</p><p style="overflow-wrap: normal !important">{url}</p>'
    return ""
chapters = []
for c in range(3):
    ps = "".join(f"<p>{para(i)}</p>" + extra(c, i) for i in range(40))
    # The last text of each chapter, which some page must show. The first
    # chapter sits in a wrapper that clips its overflow, as calibre's GitBook
    # conversions do (GH-49).
    text = f'<h1>Chapter {c+1}</h1>{ps}<p id="end-c{c}"><i>Italic tail</i> <b>bold tail</b></p>'
    if c == 0:
        text = f'<div style="overflow: hidden">{text}</div>'
    chapters.append(f'<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>C{c}</title></head><body>{text}{endings[c]}</body></html>')
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
items = "".join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(3)) + '<item id="plate" href="plate.png" media-type="image/png"/>'
spine = "".join(f'<itemref idref="c{i}"/>' for i in range(3))
z.writestr("OEBPS/content.opf", f'<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">t</dc:identifier><dc:title>T</dc:title><dc:language>en</dc:language></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>{items}</manifest><spine>{spine}</spine></package>')
z.writestr("OEBPS/nav.xhtml", '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>nav</title></head><body><nav epub:type="toc"><ol>' + "".join(f'<li><a href="c{i}.xhtml">C{i}</a></li>' for i in range(3)) + '</ol></nav></body></html>')
for i, ch in enumerate(chapters):
    z.writestr(f"OEBPS/c{i}.xhtml", ch)
z.writestr("OEBPS/plate.png", png(300, 400))
z.close()

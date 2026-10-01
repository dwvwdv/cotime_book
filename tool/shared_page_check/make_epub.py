# A book with no fonts of its own, mixing English and Chinese paragraphs:
# the case where every device falls back to its own system font.
import sys
import zipfile, random
random.seed(7)
words = "the book pages were scanned and converted to EPUB format automatically this process relies on optical character recognition and is somewhat susceptible to errors weird characters non-words incorrect guesses at structure numbering internationalization extraordinary".split()
cjk = "這本書是由網際網路檔案館以電子書格式製作的書頁經過掃描並自動轉換為電子書格式，這個過程依賴光學字元辨識，因此容易出錯。「引號」與（括號）、標點！？"
def para(i):
    if i % 3 == 2:
        return "".join(random.choice(cjk) for _ in range(random.randint(60, 220)))
    return " ".join(random.choice(words) for _ in range(random.randint(30, 120))).capitalize() + "."
chapters = []
for c in range(3):
    ps = "".join(f"<p>{para(i)}</p>" for i in range(40))
    chapters.append(f'<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>C{c}</title></head><body><h1>Chapter {c+1}</h1>{ps}<p><i>Italic tail</i> <b>bold tail</b></p></body></html>')
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
items = "".join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(3))
spine = "".join(f'<itemref idref="c{i}"/>' for i in range(3))
z.writestr("OEBPS/content.opf", f'<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">t</dc:identifier><dc:title>T</dc:title><dc:language>en</dc:language></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>{items}</manifest><spine>{spine}</spine></package>')
z.writestr("OEBPS/nav.xhtml", '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>nav</title></head><body><nav epub:type="toc"><ol>' + "".join(f'<li><a href="c{i}.xhtml">C{i}</a></li>' for i in range(3)) + '</ol></nav></body></html>')
for i, ch in enumerate(chapters):
    z.writestr(f"OEBPS/c{i}.xhtml", ch)
z.close()

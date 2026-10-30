#!/usr/bin/env python3
"""Generate the test fixtures (books, voice sample) used by the test suites.

Usage: tests/fixtures.py /tmp/mimottest
"""
import os
import struct
import sys
import zipfile

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mimottest"
os.makedirs(OUT, exist_ok=True)

# --- plain text books ------------------------------------------------------
def write_txt(name, count, template):
    path = os.path.join(OUT, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(template % (i, i) for i in range(1, count + 1)))
    print("fixture:", name)

write_txt("book2.txt", 60,
          "第%d句。这是用来测试分页提取的句子，句子编号是%d，它足够长以便多个句子分布在多个页面上。")
write_txt("big-book.txt", 8000,
          "第%d句。这是一个用于压测搜索性能的长句子，编号是%d，它包含足够的汉字以便填充页面，模拟真实小说的排版密度。")
write_txt("e2e-book.txt", 60,
          "第%d句。这是端到端测试用的长句子，编号是%d，用于验证分页提取与自动翻页朗读功能。")

# --- EPUBs with inline tags (multi text-node pages) ------------------------
CONTAINER = ('<?xml version="1.0"?><container version="1.0" '
             'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
             '<rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>'
             '</rootfiles></container>')

def write_epub(name, xhtml_files, title):
    path = os.path.join(OUT, name)
    manifest = "\n".join(
        '<item id="c%d" href="%s" media-type="application/xhtml+xml"/>' % (i, fn)
        for i, (_, fn) in enumerate(xhtml_files))
    spine = "\n".join('<itemref idref="c%d"/>' % i for i in range(len(xhtml_files)))
    opf = ('<?xml version="1.0" encoding="utf-8"?>'
           '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">'
           '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
           '<dc:title>%s</dc:title><dc:language>zh</dc:language>'
           '<dc:identifier id="id">%s</dc:identifier></metadata>'
           '<manifest>%s<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>'
           '<spine toc="ncx">%s</spine></package>') % (title, name, manifest, spine)
    navpoints = "\n".join(
        '<navPoint id="n%d" playOrder="%d"><navLabel><text>第%d章</text></navLabel>'
        '<content src="%s"/></navPoint>' % (i, i + 1, i + 1, fn)
        for i, (_, fn) in enumerate(xhtml_files))
    ncx = ('<?xml version="1.0" encoding="utf-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" '
           'version="2005-1"><head/><navMap>%s</navMap></ncx>') % navpoints
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", CONTAINER)
        z.writestr("content.opf", opf)
        z.writestr("toc.ncx", ncx)
        for text, fn in xhtml_files:
            z.writestr(fn, '<?xml version="1.0" encoding="utf-8"?>'
                       '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>x</title></head>'
                       "<body>%s</body></html>" % text)
    print("fixture:", name)

# 20 chapters x 30 paragraphs, with inline <em>/<b> to force text nodes
chapters = []
for c in range(1, 21):
    paras = "\n".join(
        "<p>第%d章第%d节。这是一个用于压测的长句子，它带有<em>内联强调</em>和<b>加粗文字</b>，"
        "用来模拟真实电子书里常见的多文本节点结构，句子会比较长以便填充屏幕。</p>" % (c, p)
        for p in range(1, 31))
    chapters.append((paras, "chap%02d.xhtml" % c))
write_epub("big-book.epub", chapters, "压测大书")

write_epub("probe.epub", [(
    "<p>甲甲甲甲 <em>乙乙乙乙</em> 丙丙丙丙。丁丁丁丁。</p>\n<p>第二段纯文本内容。</p>",
    "c1.xhtml")], "probe")

# --- 2s silent wav (voice clone sample) ------------------------------------
pcm = b"\x00\x00" * 24000 * 2
hdr = (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE"
       + b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, 24000, 48000, 2, 16)
       + b"data" + struct.pack("<I", len(pcm)))
with open(os.path.join(OUT, "tone.wav"), "wb") as f:
    f.write(hdr + pcm)
print("fixture: tone.wav")

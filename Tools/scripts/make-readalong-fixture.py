#!/usr/bin/env python3
"""Builds a readaloud EPUB matching Storyteller's aligner output byte-for-byte
in structure, so the reader can be tested without running a real alignment.

Mirrors libraries/align/src/align/align.ts at tag web-v2.14.21:
  - <span id="{chapterId}-s{n}"> around each sentence
  - MediaOverlays/{stem}.smil with a flat list of <par> at sentence granularity
  - clipBegin/clipEnd as "<seconds>.toFixed(3)s"
  - audio embedded inside the EPUB at Audio/<basename>
  - media:duration refines per overlay plus one for the book
  - media:active-class = -epub-media-overlay-active  (note the leading hyphen)

It also reproduces two things real output contains that trip up naive readers:
a ~1 ms filler entry, and a gap in sentence-id numbering caused by a footnote.
"""
import sys, zipfile, pathlib

OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "readalong.epub")

# (fragment id, text, clipBegin, clipEnd). Clips are contiguous within the
# track, exactly as collapseSentenceRangeGaps produces: clipEnd[n] == clipBegin[n+1],
# the first starts at 0.000 and the last ends at the full track duration.
CH1 = [
    ("ch01-s0", "The House had more rooms than the tide could count.", 0.000, 4.250),
    ("ch01-s1", "Each morning I walked the long gallery, past the statues whose names no one remembered.", 4.250, 11.500),
    # A ~1 ms filler entry: emitted so EPUBCheck accepts a zero-length range.
    # A reader that matches it will flash a highlight onto text never spoken.
    ("ch01-s2", "", 11.500, 11.501),
    ("ch01-s3", "Somewhere below, the water kept its own patient record of the days.", 11.501, 17.900),
    # s4 is the footnote's own sentence and lives in the notes section, so the
    # ids in this chapter jump from s3 to s5. Never assume contiguity.
    ("ch01-s5", "I had learned to trust it more than any calendar on the wall.", 17.900, 23.000),
]
CH2 = [
    ("ch02-s0", "The tides kept their own calendar, and I kept mine.", 0.000, 5.000),
    ("ch02-s1", "Between them there was rarely disagreement.", 5.000, 9.750),
]
CHAPTERS = [("ch01", "Chapter One", CH1, "track1.mp3"), ("ch02", "Chapter Two", CH2, "track2.mp3")]


def clock(seconds: float) -> str:
    total = int(seconds)
    return f"{total // 3600:02d}:{(total % 3600) // 60:02d}:{seconds % 60:05.2f}"


def xhtml(chapter_id, title, rows):
    spans = "\n".join(
        f'      <p><span id="{fid}">{text} </span></p>' for fid, text, _, _ in rows if text
    )
    return f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head>
    <title>{title}</title>
    <link rel="stylesheet" href="Styles/storyteller-readaloud.css" type="text/css"/>
  </head>
  <body>
    <section epub:type="chapter">
      <h1>{title}</h1>
{spans}
    </section>
  </body>
</html>
"""


def smil(chapter_id, rows, audio):
    pars = "\n".join(
        f"""      <par id="{fid}">
        <text src="../{chapter_id}.xhtml#{fid}"/>
        <audio src="../Audio/{audio}" clipBegin="{begin:.3f}s" clipEnd="{end:.3f}s"/>
      </par>"""
        for fid, _, begin, end in rows
    )
    return f"""<?xml version="1.0" encoding="utf-8"?>
<smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
  <body>
    <seq id="{chapter_id}_overlay" epub:textref="../{chapter_id}.xhtml" epub:type="chapter">
{pars}
    </seq>
  </body>
</smil>
"""


def opf():
    items, refs, durations = [], [], []
    total = 0.0
    for cid, _, rows, audio in CHAPTERS:
        span = sum(end - begin for _, _, begin, end in rows)
        total += span
        items.append(f'    <item id="{cid}" href="{cid}.xhtml" media-type="application/xhtml+xml" media-overlay="{cid}_overlay"/>')
        items.append(f'    <item id="{cid}_overlay" href="MediaOverlays/{cid}.smil" media-type="application/smil+xml"/>')
        items.append(f'    <item id="audio_{cid}" href="Audio/{audio}" media-type="audio/mpeg"/>')
        refs.append(f'    <itemref idref="{cid}"/>')
        durations.append(f'    <meta property="media:duration" refines="#{cid}_overlay">{clock(span)}</meta>')
    return f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.w3.org/2000/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:issa-readalong-fixture</dc:identifier>
    <dc:title>The Patient Record of the Days</dc:title>
    <dc:language>en</dc:language>
    <dc:creator>A. Fixture</dc:creator>
{chr(10).join(durations)}
    <meta property="media:duration">{clock(total)}</meta>
    <meta property="media:active-class">-epub-media-overlay-active</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="css" href="Styles/storyteller-readaloud.css" media-type="text/css"/>
{chr(10).join(items)}
  </manifest>
  <spine>
{chr(10).join(refs)}
  </spine>
</package>
"""


def nav():
    links = "\n".join(f'        <li><a href="{cid}.xhtml">{title}</a></li>' for cid, title, _, _ in CHAPTERS)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Contents</title></head>
  <body>
    <nav epub:type="toc" id="toc">
      <h1>Contents</h1>
      <ol>
{links}
      </ol>
    </nav>
  </body>
</html>
"""


with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    # Per OCF, mimetype must be first and stored uncompressed.
    z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    z.writestr("META-INF/container.xml", """<?xml version="1.0" encoding="utf-8"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
""")
    z.writestr("OEBPS/content.opf", opf())
    z.writestr("OEBPS/nav.xhtml", nav())
    z.writestr("OEBPS/Styles/storyteller-readaloud.css", ".-epub-media-overlay-active { background-color: #ffb; }\n")
    for cid, title, rows, audio in CHAPTERS:
        z.writestr(f"OEBPS/{cid}.xhtml", xhtml(cid, title, rows))
        z.writestr(f"OEBPS/MediaOverlays/{cid}.smil", smil(cid, rows, audio))
        # Placeholder audio: the reader never decodes it in these tests.
        z.writestr(f"OEBPS/Audio/{audio}", b"\xff\xfb\x90\x00" + b"\x00" * 2048)

print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")

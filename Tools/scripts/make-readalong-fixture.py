#!/usr/bin/env python3
"""Builds a readaloud EPUB matching Storyteller's aligner output byte-for-byte
in structure, so the reader can be tested without running a real alignment.

    make-readalong-fixture.py [OUT]      v2 book, readalong.epub by default
    make-readalong-fixture.py --v3 OUT   v3 book, e.g. readalong-v3.epub

The default mirrors libraries/align/src/align/align.ts at tag web-v2.14.21:
  - <span id="{chapterId}-s{n}"> around each sentence
  - MediaOverlays/{stem}.smil with a flat list of <par> at sentence granularity
  - clipBegin/clipEnd as "<seconds>.toFixed(3)s"
  - audio embedded inside the EPUB at Audio/<basename>
  - media:duration refines per overlay plus one for the book
  - media:active-class = -epub-media-overlay-active  (note the leading hyphen)

It also reproduces two things real output contains that trip up naive readers:
a ~1 ms filler entry, and a gap in sentence-id numbering caused by a footnote.
Its output is what Tests/Fixtures/readalong.epub holds, and the --v3 mode
leaves it alone: the v2 builders below are the ones that wrote that file.

--v3 mirrors the same aligner at web-v3.0.0-beta.40, where v2's folding of
untexted audio into a neighbouring sentence became explicit markup
(ctc/mediaOverlay.ts, audioChapters.ts; both aligners share them):
  - epub:prefix on <html> and on the SMIL root, each with the URL the aligner
    writes there (they differ)
  - epub:type="storyteller:sentence-span" on every sentence span
  - epub:type on every <par>: storyteller:{matched|interpolated|unmatched|
    dropped} for a sentence, storyteller:audio-only for a hole
  - per sentence N, in order: {chap}-sN-before{k} holes, the sentence's own
    par, a {chap}-sN-a{k} par for each further audio range, then
    {chap}-sN-after{k} holes. Holes and continuations point at sentence N's
    fragment, so one fragment has several pars
  - an audio chapter: spine item storyteller_audio_N holding only
    <h1 id="storyteller_audio_N-s0">, an overlay whose storyteller_audio_N-a{k}
    pars are all audio-only and all point at that heading, a depth-0 nav <li>
    beside its anchor chapter, and a media:duration refines

The v3 book puts every shape the reader has to survive into four spine items:
a before-hole opening a file, a mid-file after-hole, an after-hole running to
the end of a file that is not the last (the file-end advance that used to
loop), a two-file audio chapter behind chapter one, a sentence whose -a1
continuation starts the next file, clips that run backwards inside one file
(CTC can leave that), and an after-hole that is the last entry of the book.
Which holes join an audio chapter is chosen to fit those in, not replayed
through holes.ts: there, chapter one's short tail and an untitled audio
chapter behind it would share a boundary and be planned as one chapter.
What holes.ts does make of that audio is not in this book: an audio chapter
that opens mid-file in chapter one's track (untitled bonus tracks), or
chapter one's last sentence with an after-hole in each of three files
(titled ones). Those, and word granularity, are stated by hand in
SMILV3Tests and ReadalongV3Tests instead.
"""
import sys, zipfile, pathlib
from collections import namedtuple

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


def v2_members():
    """Every archive member after the container, in the order they were
    always written — which is part of what keeps readalong.epub unchanged."""
    yield "OEBPS/content.opf", opf()
    yield "OEBPS/nav.xhtml", nav()
    yield "OEBPS/Styles/storyteller-readaloud.css", CSS
    for cid, title, rows, audio in CHAPTERS:
        yield f"OEBPS/{cid}.xhtml", xhtml(cid, title, rows)
        yield f"OEBPS/MediaOverlays/{cid}.smil", smil(cid, rows, audio)
        yield f"OEBPS/Audio/{audio}", PLACEHOLDER_AUDIO


CSS = ".-epub-media-overlay-active { background-color: #ffb; }\n"
# Placeholder audio: the reader never decodes it in these tests.
PLACEHOLDER_AUDIO = b"\xff\xfb\x90\x00" + b"\x00" * 2048


# --- v3 ----------------------------------------------------------------------

# Two different URLs, as the aligner writes them: markup.ts stamps the html
# element, mediaOverlay.ts the smil root.
XHTML_PREFIX = "storyteller: https://storyteller-platform.dev/docs/vocabulary"
SMIL_PREFIX = "storyteller: https://storyteller-platform.gitlab.io/storyteller/docs/vocabulary"
AUDIO_ONLY = "storyteller:audio-only"

# One sentence as mediaOverlay.ts sees it: its number, its text, its alignment
# state, its audio ranges (one, or more when it spans files), and the holes
# collapseRanges anchored before and after it. A clip is (file, begin, end).
Sentence = namedtuple("Sentence", "n text state ranges before after", defaults=((), ()))

# File lengths, which is where a hole running to the end of a file ends, and
# what the book's own media:duration adds up. In the order the aligner was
# handed them, which is the order the book reaches them.
V3_AUDIO = {
    "track1.mp3": 44.000,
    "bonus1.mp3": 180.000,
    "bonus2.mp3": 150.000,
    "track2a.mp3": 9.750,
    "track2b.mp3": 8.000,
    "track3.mp3": 33.000,
}

V3_CH1 = [
    # A before-hole opening the file: in v2 these 6.5 s belonged to s0's clip,
    # which then started at zero.
    Sentence(0, "The House had more rooms than the tide could count.", "matched",
             [("track1.mp3", 6.500, 10.750)],
             before=[("track1.mp3", 0.000, 6.500)],
             # A mid-file gap longer than five seconds becomes an after-hole of
             # the sentence before it. v2 stretched that sentence over it.
             after=[("track1.mp3", 10.750, 17.000)]),
    Sentence(1, "Each morning I walked the long gallery, past the statues whose names no one remembered.", "matched",
             [("track1.mp3", 17.000, 24.250)]),
    # The ~1 ms filler, as v3 writes a dropped sentence (DROPPED_WIDTH).
    Sentence(2, "", "dropped", [("track1.mp3", 24.250, 24.251)]),
    Sentence(3, "Somewhere below, the water kept its own patient record of the days.", "interpolated",
             [("track1.mp3", 24.251, 30.650)]),
    # s4 lives in the notes section, so the ids jump from s3 to s5.
    Sentence(5, "I had learned to trust it more than any calendar on the wall.", "matched",
             [("track1.mp3", 30.650, 35.750)],
             # Runs to the end of a file that is not the last. The file ends on
             # a hole that names s5's fragment, which is the loop: an advance
             # that resolved the hole back to s5 found the hole again after it.
             after=[("track1.mp3", 35.750, 44.000)]),
]
V3_CH2 = [
    Sentence(0, "The tides kept their own calendar, and I kept mine.", "matched",
             [("track2a.mp3", 0.000, 5.000)]),
    # Ends one file and continues into the next: the second range is par
    # ch02-s1-a1, a continuation of the same sentence, not a sentence of its own.
    Sentence(1, "Between them there was rarely disagreement.", "matched",
             [("track2a.mp3", 5.000, 9.750), ("track2b.mp3", 0.000, 3.500)]),
    Sentence(2, "When there was, the tide was always right.", "interpolated",
             [("track2b.mp3", 3.500, 8.000)]),
]
V3_CH3 = [
    Sentence(0, "At the turn of the year the lower halls filled again.", "matched",
             [("track3.mp3", 0.000, 4.000)]),
    # Clips that run backwards inside one file, which CTC can leave: s1 is
    # heard after s2 and s3. A lookup that assumes clip order is reading order
    # binary-searches past them.
    Sentence(1, "I counted the steps to the water and found one fewer than before.", "unmatched",
             [("track3.mp3", 14.000, 19.000)]),
    Sentence(2, "The statues did not seem to mind.", "interpolated",
             [("track3.mp3", 4.000, 9.000)]),
    Sentence(3, "Their faces were turned toward the sea, as they had always been.", "matched",
             [("track3.mp3", 9.000, 14.000)]),
    # Two seconds of nothing between 19 and 21: under the five-second hole
    # threshold, and left as a gap so a lookup has to answer "no sentence".
    Sentence(4, "I closed the ledger and listened to the tide come in.", "matched",
             [("track3.mp3", 21.000, 25.000)],
             # The last entry of the book: the end-of-book pause.
             after=[("track3.mp3", 25.000, 33.000)]),
]
V3_CHAPTERS = [
    ("ch01", "Chapter One", V3_CH1),
    ("ch02", "Chapter Two", V3_CH2),
    ("ch03", "Chapter Three", V3_CH3),
]
# (id, title, anchor chapter, holes). Over the 300 s audioChapterSeconds
# threshold, in two whole files, so its end is a file end too. Titled the way
# positionalTitle names an untitled one placed after its anchor.
V3_AUDIO_CHAPTERS = [
    ("storyteller_audio_1", "After Chapter One", "ch01",
     [("bonus1.mp3", 0.000, 180.000), ("bonus2.mp3", 0.000, 150.000)]),
]


def v3_par(par_id, kind, chapter_href, fragment, clip):
    audio, begin, end = clip
    return f"""      <par id="{par_id}" epub:type="{kind}">
        <text src="../{chapter_href}#{fragment}"/>
        <audio src="../Audio/{audio}" clipBegin="{begin:.3f}s" clipEnd="{end:.3f}s"/>
      </par>"""


def v3_pars(chapter_id, sentences):
    """createTextRangeSmallSequences at sentence granularity."""
    pars = []
    for s in sentences:
        fragment = f"{chapter_id}-s{s.n}"
        href = f"{chapter_id}.xhtml"
        for k, hole in enumerate(s.before):
            pars.append(v3_par(f"{fragment}-before{k}", AUDIO_ONLY, href, fragment, hole))
        for k, clip in enumerate(s.ranges):
            par_id = fragment if k == 0 else f"{fragment}-a{k}"
            pars.append(v3_par(par_id, f"storyteller:{s.state}", href, fragment, clip))
        for k, hole in enumerate(s.after):
            pars.append(v3_par(f"{fragment}-after{k}", AUDIO_ONLY, href, fragment, hole))
    return pars


def v3_smil(chapter_id, chapter_href, pars):
    body = "\n".join(pars)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0" epub:prefix="{SMIL_PREFIX}">
  <body>
    <seq id="{chapter_id}_overlay" epub:textref="../{chapter_href}" epub:type="chapter">
{body}
    </seq>
  </body>
</smil>
"""


def v3_xhtml(chapter_id, title, sentences):
    spans = "\n".join(
        f'      <p><span id="{chapter_id}-s{s.n}" epub:type="storyteller:sentence-span">{s.text} </span></p>'
        for s in sentences if s.text
    )
    return f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" epub:prefix="{XHTML_PREFIX}">
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


def v3_audio_chapter_xhtml(chapter_id, title):
    """writeAudioChapters' new document: a heading and nothing else, and no
    storyteller prefix, because markup never ran over it."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
  <head>
    <title>{title}</title>
    <link rel="stylesheet" type="text/css" href="Styles/storyteller-readaloud.css"/>
  </head>
  <body>
    <section epub:type="chapter">
      <h1 id="{chapter_id}-s0">{title}</h1>
    </section>
  </body>
</html>
"""


def v3_chapter_duration(clips):
    """getChapterDuration: each file's extent, summed, over clips sorted by
    file order and then by start."""
    order = list(V3_AUDIO)
    duration, current, start, end = 0.0, None, 0.0, 0.0
    for audio, begin, finish in sorted(clips, key=lambda c: (order.index(c[0]), c[1])):
        if audio != current:
            duration += end - start
            start, current = begin, audio
        end = finish
    return duration + (end - start)


def v3_sentence_clips(sentences):
    return [clip for s in sentences for clip in (*s.before, *s.ranges, *s.after)]


def v3_spine():
    """(id, href, title) in reading order, each audio chapter spliced in
    right after its anchor as writeAudioChapters does for position "after"."""
    spine = [(cid, f"{cid}.xhtml", title) for cid, title, _ in V3_CHAPTERS]
    for aid, title, anchor, _ in V3_AUDIO_CHAPTERS:
        index = next(i for i, (cid, _, _) in enumerate(spine) if cid == anchor)
        spine.insert(index + 1, (aid, f"storyteller-audio-{aid.rsplit('_', 1)[1]}.xhtml", title))
    return spine


def v3_opf():
    items, refs, durations = [], [], []
    for cid, _, sentences in V3_CHAPTERS:
        items.append(f'    <item id="{cid}" href="{cid}.xhtml" media-type="application/xhtml+xml" media-overlay="{cid}_overlay"/>')
        items.append(f'    <item id="{cid}_overlay" href="MediaOverlays/{cid}.smil" media-type="application/smil+xml"/>')
        durations.append(
            f'    <meta property="media:duration" refines="#{cid}_overlay">'
            f'{clock(v3_chapter_duration(v3_sentence_clips(sentences)))}</meta>')
    # writeAudioChapters runs after every text chapter is written, so its
    # manifest items and refines come after theirs.
    for aid, _, _, holes in V3_AUDIO_CHAPTERS:
        n = aid.rsplit("_", 1)[1]
        items.append(f'    <item id="{aid}" href="storyteller-audio-{n}.xhtml" media-type="application/xhtml+xml" media-overlay="{aid}_overlay"/>')
        items.append(f'    <item id="{aid}_overlay" href="MediaOverlays/storyteller-audio-{n}.smil" media-type="application/smil+xml"/>')
        durations.append(
            f'    <meta property="media:duration" refines="#{aid}_overlay">{clock(v3_chapter_duration(holes))}</meta>')
    for audio in V3_AUDIO:
        stem = audio.rsplit(".", 1)[0]
        items.append(f'    <item id="audio_{stem}" href="Audio/{audio}" media-type="audio/mpeg"/>')
    refs = [f'    <itemref idref="{sid}"/>' for sid, _, _ in v3_spine()]
    total = sum(V3_AUDIO.values())
    return f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.w3.org/2000/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:issa-readalong-fixture-v3</dc:identifier>
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


def v3_nav():
    # Depth 0, straight after the anchor's own entry: insertNavEntry splices
    # the new <li> into the list that holds the anchor's.
    links = "\n".join(f'        <li><a href="{href}">{title}</a></li>' for _, href, title in v3_spine())
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


def v3_members():
    yield "OEBPS/content.opf", v3_opf()
    yield "OEBPS/nav.xhtml", v3_nav()
    yield "OEBPS/Styles/storyteller-readaloud.css", CSS
    for cid, title, sentences in V3_CHAPTERS:
        yield f"OEBPS/{cid}.xhtml", v3_xhtml(cid, title, sentences)
        yield f"OEBPS/MediaOverlays/{cid}.smil", v3_smil(cid, f"{cid}.xhtml", v3_pars(cid, sentences))
    for aid, title, _, holes in V3_AUDIO_CHAPTERS:
        n = aid.rsplit("_", 1)[1]
        href = f"storyteller-audio-{n}.xhtml"
        yield f"OEBPS/{href}", v3_audio_chapter_xhtml(aid, title)
        # createAudioChapterOverlay: every par audio-only, every one pointing
        # at the heading, numbered -a{k} across however many files it spans.
        pars = [v3_par(f"{aid}-a{k}", AUDIO_ONLY, href, f"{aid}-s0", hole) for k, hole in enumerate(holes)]
        yield f"OEBPS/MediaOverlays/storyteller-audio-{n}.smil", v3_smil(aid, href, pars)
    for audio in V3_AUDIO:
        yield f"OEBPS/Audio/{audio}", PLACEHOLDER_AUDIO


def write(out, members):
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        # Per OCF, mimetype must be first and stored uncompressed.
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", """<?xml version="1.0" encoding="utf-8"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
""")
        for name, data in members:
            z.writestr(name, data)
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--v3"]:
        if len(args) != 2:
            sys.exit("usage: make-readalong-fixture.py [OUT] | --v3 OUT")
        write(pathlib.Path(args[1]), v3_members())
    else:
        write(pathlib.Path(args[0] if args else "readalong.epub"), v2_members())

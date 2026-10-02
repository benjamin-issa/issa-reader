#!/usr/bin/env python3
"""Builds the EPUBs the local-books import is tested against.

    make-local-import-fixtures.py [OUT_DIR]

OUT_DIR defaults to Packages/IssaEPUB/Tests/Fixtures. Every book is written
from invented text, so none of it is anyone's prose but this repository's.

  drm-adobe.epub              Adobe ADEPT, as Adobe Digital Editions and most
                              library loans deliver it: META-INF/rights.xml
                              and an encryption.xml that encrypts the chapters
                              with aes128-cbc. Must be refused as locked.
  drm-lcp.epub                Readium LCP: META-INF/license.lcpl and chapters
                              encrypted aes256-cbc, the licence named by a
                              RetrievalMethod. Must be refused as locked.
  drm-lcp-no-licence.epub     The same with the licence file missing, so only
                              encryption.xml's RetrievalMethod says whose lock
                              it is.
  epub2-meta-cover.epub       EPUB 2.0 with an NCX, whose cover is named only by
                              <meta name="cover"> — the image's id and path say
                              nothing about covers — and whose creators carry
                              opf:role and opf:file-as, a narrator among them,
                              plus Calibre's series metadata.
  epub3-details.epub          EPUB 3, fixed layout, with a subtitle (title-type),
                              a series (belongs-to-collection + group-position),
                              an illustrator, a contributor with no role, a
                              publisher, a description and a unique identifier
                              that is not the first identifier.
  readalong-repeated-ids.epub A read-along whose sentence ids restart in every
                              chapter (s0, s1, … in each), as books from tools
                              other than Storyteller do.
  readalong-opus.epub         A read-along whose audio is Opus in .opus files
                              (audio/opus), which AVFoundation does not play:
                              added as text, with a notice.
  readalong-open-clips.epub   A read-along whose clips carry no clipEnd ("to the
                              end of the media").

Audio is placeholder bytes: nothing here decodes it, and the import only reads
what the manifest declares. Members are stored, not deflated, like the other
generated fixtures, so the bytes are legible.
"""
import pathlib
import struct
import sys
import zipfile
import zlib

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

PLACEHOLDER_AUDIO = b"\xff\xfb\x90\x00" + b"\x00" * 2048
# An Ogg page header, then nothing a decoder could use: the media type is what
# is under test.
PLACEHOLDER_OPUS = b"OggS\x00\x02" + b"\x00" * 20 + b"OpusHead" + b"\x00" * 1024

# Invented prose, two chapters' worth, reused by every book.
CHAPTER_TEXT = [
    ("Chapter One", [
        "The lighthouse keeper counted ships the way other people counted sheep.",
        "On calm nights there were none, and she slept badly.",
        "On stormy ones she did not sleep at all, and was glad of it.",
    ]),
    ("Chapter Two", [
        "In spring a letter came addressed to the lamp rather than to her.",
        "She read it aloud to the lamp, which seemed only fair.",
    ]),
]


def png(width=2, height=3, rgb=(226, 133, 58)):
    """A real PNG, so an image decoder can make a thumbnail of it."""
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


def chapter_xhtml(title, sentences, ids=None, doctype=""):
    ids = ids or [None] * len(sentences)
    paragraphs = "\n".join(
        f'    <p><span id="{i}">{s}</span></p>' if i else f"    <p>{s}</p>"
        for i, s in zip(ids, sentences))
    return f"""<?xml version="1.0" encoding="utf-8"?>{doctype}
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>{title}</title></head>
  <body>
    <h1>{title}</h1>
{paragraphs}
  </body>
</html>
"""


def nav(chapters):
    links = "\n".join(f'      <li><a href="{href}">{title}</a></li>' for href, title in chapters)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Contents</title></head>
  <body>
    <nav epub:type="toc" id="toc">
      <ol>
{links}
      </ol>
    </nav>
  </body>
</html>
"""


def write(path, members):
    """mimetype first and stored, as the OCF requires; everything else stored
    too. Dated once, so running this again writes the same bytes."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
        for name, data in [("mimetype", "application/epub+zip"), ("META-INF/container.xml", CONTAINER)] + members:
            z.writestr(zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0)), data)
    print("wrote", path)


def plain_epub3(identifier, title, extra_manifest="", extra_metadata="", leading_metadata=""):
    """A small, valid EPUB 3: a nav and two chapters."""
    items = "\n".join(
        f'    <item id="ch{n}" href="ch{n}.xhtml" media-type="application/xhtml+xml"/>'
        for n in (1, 2))
    opf = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
{leading_metadata}
    <dc:identifier id="uid">{identifier}</dc:identifier>
    <dc:title>{title}</dc:title>
    <dc:language>en</dc:language>
    <dc:creator>A. Fixture</dc:creator>
{extra_metadata}
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
{items}
{extra_manifest}
  </manifest>
  <spine>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>
"""
    members = [("OEBPS/content.opf", opf),
               ("OEBPS/nav.xhtml", nav([("ch1.xhtml", "Chapter One"), ("ch2.xhtml", "Chapter Two")]))]
    for n, (heading, sentences) in enumerate(CHAPTER_TEXT, start=1):
        members.append((f"OEBPS/ch{n}.xhtml", chapter_xhtml(heading, sentences)))
    return members


def drm_adobe(out):
    members = plain_epub3("urn:uuid:issa-fixture-drm-adobe", "A Locked Book")
    # The chapters as ciphertext would be: not XHTML at all.
    members = [(n, b"\x8a\x13" * 200) if n.startswith("OEBPS/ch") else (n, d) for n, d in members]
    rights = """<?xml version="1.0"?>
<adept:rights xmlns:adept="http://ns.adobe.com/adept">
  <adept:licenseToken>
    <adept:user>urn:uuid:00000000-0000-4000-8000-000000000000</adept:user>
    <adept:resource>urn:uuid:issa-fixture-drm-adobe</adept:resource>
  </adept:licenseToken>
</adept:rights>
"""
    encryption = """<?xml version="1.0"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
    <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
    <KeyInfo xmlns="http://www.w3.org/2000/09/xmldsig#">
      <resource xmlns="http://ns.adobe.com/adept">urn:uuid:issa-fixture-drm-adobe</resource>
    </KeyInfo>
    <CipherData><CipherReference URI="OEBPS/ch1.xhtml"/></CipherData>
  </EncryptedData>
  <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
    <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
    <CipherData><CipherReference URI="OEBPS/ch2.xhtml"/></CipherData>
  </EncryptedData>
</encryption>
"""
    write(out / "drm-adobe.epub", [("META-INF/rights.xml", rights), ("META-INF/encryption.xml", encryption)] + members)


def lcp_encryption():
    entries = "\n".join(f"""  <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
    <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes256-cbc"/>
    <KeyInfo xmlns="http://www.w3.org/2000/09/xmldsig#">
      <RetrievalMethod URI="license.lcpl#/encryption/content_key" Type="http://readium.org/2014/01/lcp#EncryptedContentKey"/>
    </KeyInfo>
    <CipherData><CipherReference URI="OEBPS/ch{n}.xhtml"/></CipherData>
  </EncryptedData>""" for n in (1, 2))
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
{entries}
</encryption>
"""


def drm_lcp(out, with_licence=True):
    members = plain_epub3("urn:uuid:issa-fixture-drm-lcp", "A Licensed Book")
    members = [(n, b"\x5c\x01" * 200) if n.startswith("OEBPS/ch") else (n, d) for n, d in members]
    licence = """{"id": "00000000-0000-4000-8000-000000000001", "issued": "2026-01-01T00:00:00Z",
 "provider": "https://provider.example", "encryption": {"profile": "http://readium.org/lcp/basic-profile",
 "content_key": {"algorithm": "http://www.w3.org/2001/04/xmlenc#aes256-cbc", "encrypted_value": "AAAA"},
 "user_key": {"algorithm": "http://www.w3.org/2001/04/xmlenc#sha256", "text_hint": "invented"}},
 "links": [], "rights": {}}
"""
    extra = [("META-INF/license.lcpl", licence)] if with_licence else []
    name = "drm-lcp.epub" if with_licence else "drm-lcp-no-licence.epub"
    write(out / name, extra + [("META-INF/encryption.xml", lcp_encryption())] + members)


def epub2_meta_cover(out):
    opf = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="BookId">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>The Keeper of the Lamp</dc:title>
    <dc:creator opf:role="aut" opf:file-as="Fixture, Ada">Ada Fixture</dc:creator>
    <dc:creator opf:role="nrt" opf:file-as="Reader, Noel">Noel Reader</dc:creator>
    <dc:contributor opf:role="trl">Tomas Translator</dc:contributor>
    <dc:language>en</dc:language>
    <dc:identifier id="BookId" opf:scheme="UUID">urn:uuid:issa-fixture-epub2</dc:identifier>
    <dc:date>1911</dc:date>
    <meta name="cover" content="img-front"/>
    <meta name="calibre:series" content="Lamps and Ledgers"/>
    <meta name="calibre:series_index" content="2"/>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="img-front" href="images/frontispiece.png" media-type="image/png"/>
    <item id="img-map" href="images/map.png" media-type="image/png"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>
"""
    ncx = """<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:issa-fixture-epub2"/></head>
  <docTitle><text>The Keeper of the Lamp</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>Chapter One</text></navLabel><content src="ch1.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>Chapter Two</text></navLabel><content src="ch2.xhtml"/></navPoint>
  </navMap>
</ncx>
"""
    doctype = '\n<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">'
    members = [("OEBPS/content.opf", opf), ("OEBPS/toc.ncx", ncx),
               ("OEBPS/images/frontispiece.png", png()), ("OEBPS/images/map.png", png(rgb=(124, 138, 90)))]
    for n, (heading, sentences) in enumerate(CHAPTER_TEXT, start=1):
        members.append((f"OEBPS/ch{n}.xhtml", chapter_xhtml(heading, sentences, doctype=doctype)))
    write(out / "epub2-meta-cover.epub", members)


def epub3_details(out):
    # Before the unique identifier, so "the first identifier" is the wrong one.
    leading = '    <dc:identifier id="isbn">urn:isbn:0000000000000</dc:identifier>'
    metadata = """    <dc:title id="t2">Further Notes on Lamps</dc:title>
    <meta refines="#t2" property="title-type">subtitle</meta>
    <dc:creator id="ill">Iris Illustrator</dc:creator>
    <meta refines="#ill" property="role" scheme="marc:relators">ill</meta>
    <dc:contributor>Casey Contributor</dc:contributor>
    <dc:publisher>Invented Press</dc:publisher>
    <dc:description>A short book about a lighthouse, invented for a test.</dc:description>
    <dc:date>2026-05-01</dc:date>
    <meta property="belongs-to-collection" id="c1">Lamps and Ledgers</meta>
    <meta refines="#c1" property="collection-type">series</meta>
    <meta refines="#c1" property="group-position">3</meta>
    <meta property="rendition:layout">pre-paginated</meta>"""
    # The title element comes first, so the main title is "The Lighthouse Book"
    # whatever order the subtitle is written in.
    members = plain_epub3("urn:uuid:issa-fixture-epub3-details", "The Lighthouse Book",
                          extra_metadata=metadata, leading_metadata=leading)
    write(out / "epub3-details.epub", members)


def readalong(out, name, identifier, title, ids_for, audio_files, media_type, clip_end=True, audio_bytes=PLACEHOLDER_AUDIO):
    """A two-chapter read-along. ids_for(chapter_number, sentence_index) names
    each sentence span; audio_files[n] is chapter n's track."""
    items, refs, overlays = [], [], []
    members = []
    total = 0.0
    for n, (heading, sentences) in enumerate(CHAPTER_TEXT, start=1):
        ids = [ids_for(n, i) for i in range(len(sentences))]
        members.append((f"OEBPS/ch{n}.xhtml", chapter_xhtml(heading, sentences, ids)))
        pars = []
        for i, fid in enumerate(ids):
            begin, end = i * 3.0, (i + 1) * 3.0
            end_attr = f' clipEnd="{end:.3f}s"' if clip_end else ""
            pars.append(f"""      <par id="p{n}-{i}">
        <text src="../ch{n}.xhtml#{fid}"/>
        <audio src="../Audio/{audio_files[n]}" clipBegin="{begin:.3f}s"{end_attr}/>
      </par>""")
        total += 3.0 * len(ids)
        overlays.append((f"OEBPS/MediaOverlays/ch{n}.smil", f"""<?xml version="1.0" encoding="utf-8"?>
<smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
  <body>
    <seq id="ch{n}_overlay" epub:textref="../ch{n}.xhtml">
{chr(10).join(pars)}
    </seq>
  </body>
</smil>
"""))
        items.append(f'    <item id="ch{n}" href="ch{n}.xhtml" media-type="application/xhtml+xml" media-overlay="ch{n}_overlay"/>')
        items.append(f'    <item id="ch{n}_overlay" href="MediaOverlays/ch{n}.smil" media-type="application/smil+xml"/>')
        items.append(f'    <item id="audio{n}" href="Audio/{audio_files[n]}" media-type="{media_type}"/>')
        refs.append(f'    <itemref idref="ch{n}"/>')
    seconds = int(total)
    opf = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">{identifier}</dc:identifier>
    <dc:title>{title}</dc:title>
    <dc:language>en</dc:language>
    <dc:creator>A. Fixture</dc:creator>
    <meta property="media:duration">00:00:{seconds:02d}.00</meta>
    <meta property="media:active-class">-epub-media-overlay-active</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
{chr(10).join(items)}
  </manifest>
  <spine>
{chr(10).join(refs)}
  </spine>
</package>
"""
    members = [("OEBPS/content.opf", opf),
               ("OEBPS/nav.xhtml", nav([("ch1.xhtml", "Chapter One"), ("ch2.xhtml", "Chapter Two")]))] \
        + members + overlays \
        + [(f"OEBPS/Audio/{audio_files[n]}", audio_bytes) for n in (1, 2)]
    write(out / name, members)


def main():
    out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else \
        pathlib.Path(__file__).resolve().parents[2] / "Packages/IssaEPUB/Tests/Fixtures"
    out.mkdir(parents=True, exist_ok=True)
    drm_adobe(out)
    drm_lcp(out)
    drm_lcp(out, with_licence=False)
    epub2_meta_cover(out)
    epub3_details(out)
    readalong(out, "readalong-repeated-ids.epub", "urn:uuid:issa-fixture-repeated-ids",
              "The Repeated Sentences", lambda n, i: f"s{i}",
              {1: "ch1.mp3", 2: "ch2.mp3"}, "audio/mpeg")
    readalong(out, "readalong-opus.epub", "urn:uuid:issa-fixture-opus",
              "The Opus Narration", lambda n, i: f"ch{n}-s{i}",
              {1: "ch1.opus", 2: "ch2.opus"}, "audio/opus", audio_bytes=PLACEHOLDER_OPUS)
    readalong(out, "readalong-open-clips.epub", "urn:uuid:issa-fixture-open-clips",
              "The Open Clips", lambda n, i: f"ch{n}-s{i}",
              {1: "ch1.mp3", 2: "ch2.mp3"}, "audio/mpeg", clip_end=False)


if __name__ == "__main__":
    main()

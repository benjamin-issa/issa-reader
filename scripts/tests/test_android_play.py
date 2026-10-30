#!/usr/bin/env python3
"""Tests for scripts/android-play.py, against a stub on the loopback interface.

    python3 scripts/tests/test_android_play.py

Nothing here talks to Google Play, and no key is read: the module's hosts and
token are replaced before any request is made.

What they hold the client to:
  - an upload makes a *draft* release of the version code Play assigned, on the
    track asked for, and commits the edit;
  - a command that fails part-way deletes its edit rather than committing half
    of it;
  - listing text over Play's limits is refused before anything is sent.
"""

import importlib.util
import json
import os
import socketserver
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("android_play", os.path.join(HERE, "..", "android-play.py"))
play = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(play)


class LoopbackServer(ThreadingHTTPServer):
    """A server that skips HTTPServer's reverse-DNS lookup of its own address,
    which a Mac can take half a minute to answer for 127.0.0.1."""

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class Stub(BaseHTTPRequestHandler):
    """Play's edits, as far as the client uses them."""
    seen = []
    queries = []
    fail_track = False

    def log_message(self, *args):
        pass

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def reply(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record(self):
        raw = self.body()
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = f"<{len(raw)} bytes>"
        path, _, query = self.path.partition("?")
        Stub.seen.append((self.command, path, parsed))
        Stub.queries.append((self.command, path, query))

    def do_POST(self):
        self.record()
        if self.path.endswith("/edits"):
            return self.reply({"id": "edit-1"})
        if "/bundles" in self.path:
            return self.reply({"versionCode": 7})
        return self.reply({})

    def do_PUT(self):
        self.record()
        if Stub.fail_track and "/tracks/" in self.path:
            return self.reply({"error": {"message": "Only releases with status draft may be created on draft app."}}, 400)
        return self.reply({})

    def do_DELETE(self):
        self.record()
        self.reply({})

    def do_GET(self):
        self.record()
        self.reply({"tracks": []})


class AndroidPlayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = LoopbackServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{cls.server.server_port}"
        play.HOST = base
        play.UPLOAD_HOST = f"{base}/upload"
        play._token_cache["token"] = "test-token"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Stub.seen = []
        Stub.queries = []
        Stub.fail_track = False
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def bundle(self):
        path = self.dir / "app.aab"
        path.write_bytes(b"PK\x03\x04 not really a bundle")
        return path

    def test_an_upload_is_a_draft_release_of_the_assigned_code(self):
        notes = self.dir / "notes.txt"
        notes.write_text("First release.\n")
        play.upload(self.bundle(), ["alpha"], notes)
        puts = [entry for entry in Stub.seen if entry[0] == "PUT"]
        self.assertEqual(len(puts), 1)
        method, path, body = puts[0]
        self.assertTrue(path.endswith("/edits/edit-1/tracks/alpha"))
        release = body["releases"][0]
        self.assertEqual(release["status"], "draft")
        self.assertEqual(release["versionCodes"], ["7"])
        self.assertEqual(release["releaseNotes"], [{"language": "en-US", "text": "First release."}])
        self.assertEqual(Stub.seen[-1][:2], ("POST", f"/androidpublisher/v3/applications/{play.PACKAGE}/edits/edit-1:commit"))
        # The bundle goes to the upload host, as a media upload.
        uploads = [(path, query) for method, path, query in Stub.queries if path.endswith("/bundles")]
        self.assertEqual(uploads, [(f"/upload/androidpublisher/v3/applications/{play.PACKAGE}/edits/edit-1/bundles", "uploadType=media")])

    def test_one_upload_drafts_the_same_code_on_every_track_named(self):
        play.upload(self.bundle(), ["internal", "alpha"], None)
        uploads = [path for method, path, _ in Stub.seen if path.endswith("/bundles")]
        self.assertEqual(len(uploads), 1, "the bundle was uploaded more than once")
        puts = {path.rsplit("/", 1)[1]: body["releases"][0] for method, path, body in Stub.seen if method == "PUT"}
        self.assertEqual(set(puts), {"internal", "alpha"})
        for release in puts.values():
            self.assertEqual(release, {"versionCodes": ["7"], "status": "draft"})

    def test_a_failed_command_deletes_its_edit_instead_of_committing(self):
        Stub.fail_track = True
        with self.assertRaises(play.PlayError):
            play.upload(self.bundle(), ["alpha"], None)
        self.assertFalse(any(path.endswith(":commit") for _, path, _ in Stub.seen))
        self.assertEqual(Stub.seen[-1][0], "DELETE")

    def test_listing_text_over_the_limits_is_refused_before_anything_is_sent(self):
        locale = self.dir / "en-US"
        locale.mkdir()
        (locale / "title.txt").write_text("A title much longer than thirty characters")
        (locale / "short_description.txt").write_text("short")
        (locale / "full_description.txt").write_text("full")
        with self.assertRaises(SystemExit):
            play.listing(self.dir)
        self.assertEqual(Stub.seen, [])


if __name__ == "__main__":
    unittest.main()

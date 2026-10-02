#!/usr/bin/env python3
"""Tests for scripts/asc-api.py, against a stub on the loopback interface.

    python3 scripts/tests/test_asc_api.py

Nothing here talks to App Store Connect, and no key is read: the module's
HOST, token and app lookup are replaced before any request is made.

What they hold the client to:
  - `builds` asks for the newest first and follows `links.next` to the end,
    so a number past the first page of 200 is still seen by release.sh's
    duplicate-build guard;
  - `platforms` follows `links.next` too;
  - a server that accepts the connection and never answers ends the call
    with a message instead of blocking release.sh for ever;
  - a `links.next` that leaves App Store Connect's host is refused rather
    than sent the token.
"""

import importlib.util
import json
import os
import socket
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("asc_api", os.path.join(HERE, "..", "asc-api.py"))
asc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(asc)


class Stub(BaseHTTPRequestHandler):
    """Builds 1...TOTAL in pages of PAGE, oldest first unless sort=-version."""
    TOTAL = 248
    PAGE = 200
    seen = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        Stub.seen.append(self.path)
        url = urllib.parse.urlparse(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        host = "http://%s:%d" % self.server.server_address
        if url.path == "/v1/builds":
            numbers = list(range(1, Stub.TOTAL + 1))
            if query.get("sort") == "-version":
                numbers.reverse()
            start = int(query.get("cursor", "0"))
            page = numbers[start:start + Stub.PAGE]
            body = {"data": [{"attributes": {"version": str(n)}} for n in page], "links": {}}
            if start + Stub.PAGE < len(numbers):
                rest = dict(query, cursor=str(start + Stub.PAGE))
                body["links"]["next"] = host + url.path + "?" + urllib.parse.urlencode(rest)
            return self.reply(body)
        if url.path == "/v1/apps/APP/appStoreVersions":
            if query.get("cursor") == "1":
                return self.reply({"data": [{"attributes": {"platform": "MAC_OS"}}], "links": {}})
            return self.reply({"data": [{"attributes": {"platform": "IOS"}}],
                               "links": {"next": host + url.path + "?cursor=1"}})
        if url.path == "/v1/elsewhere":
            return self.reply({"data": [], "links": {"next": "https://example.com/v1/builds?cursor=1"}})
        self.reply({"errors": []}, 404)

    def reply(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class AscApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.host = "http://%s:%d" % cls.server.server_address

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Stub.seen = []
        self.saved = (asc.HOST, asc._token, asc.app_id)
        asc.HOST = self.host
        asc._token = lambda: "stub-token"
        asc.app_id = lambda: "APP"

    def tearDown(self):
        asc.HOST, asc._token, asc.app_id = self.saved

    def test_builds_sees_every_page(self):
        versions = asc.builds("IOS")
        self.assertEqual(len(versions), Stub.TOTAL)
        self.assertIn("248", versions)
        self.assertIn("1", versions)

    def test_builds_asks_for_the_newest_first(self):
        asc.builds("IOS")
        self.assertIn("sort=-version", urllib.parse.unquote(Stub.seen[0]))

    def test_platforms_follow_the_next_link(self):
        self.assertEqual(asc.platforms(), ["IOS", "MAC_OS"])

    def test_a_next_link_off_the_host_is_refused(self):
        with self.assertRaises(SystemExit):
            asc.paged("/v1/elsewhere")

    def test_a_server_that_never_answers_ends_the_call(self):
        silent = socket.socket()
        silent.bind(("127.0.0.1", 0))
        silent.listen(1)
        asc.HOST = "http://127.0.0.1:%d" % silent.getsockname()[1]
        saved = asc.TIMEOUT
        asc.TIMEOUT = 1
        try:
            with self.assertRaises(SystemExit) as raised:
                asc.call("GET", "/v1/apps")
            self.assertIn("did not answer", str(raised.exception.code))
        finally:
            asc.TIMEOUT = saved
            silent.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/bin/bash
# Delivers links to a running app for the UI tests that need one.
#
# `XCUIApplication.open` relaunches the app, so a test that wants a link to
# find a reader already open raises /tmp/issa-test-link.flag with the book's
# uuid in it, and this sends it with `simctl openurl`, which reaches the
# running app. Leave it running beside the test run:
#
#   scripts/deliver-test-links.sh <simulator udid> &
set -u
udid="${1:?usage: deliver-test-links.sh <simulator udid>}"
flag=/tmp/issa-test-link.flag
while true; do
  if [ -f "$flag" ]; then
    id=$(cat "$flag")
    rm -f "$flag"
    xcrun simctl openurl "$udid" "issareader://book/$id"
  fi
  sleep 0.3
done

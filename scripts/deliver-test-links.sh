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
# What `simctl openurl` answered for the last link, written after it ran: the
# test that raised the flag reads it, since the flag disappearing says only that
# this took it, not that the system accepted the link.
ack=/tmp/issa-test-link.ack
# A flag left by a test that ran with no watcher is not a link for this run,
# and the flag is not left behind when this stops either.
rm -f "$flag" "$ack"
trap 'rm -f "$flag" "$ack"' EXIT
trap 'exit 0' INT TERM
while true; do
  if [ -f "$flag" ]; then
    id=$(cat "$flag")
    rm -f "$flag"
    xcrun simctl openurl "$udid" "issareader://book/$id"
    # Written whole and moved into place, so the test never reads half of it.
    echo "$?" > "$ack.tmp"
    mv -f "$ack.tmp" "$ack"
  fi
  sleep 0.3
done

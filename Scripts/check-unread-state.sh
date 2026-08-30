#!/usr/bin/env bash
set -euo pipefail

# State that is written and never read, and methods reachable only from tests.
#
# Four separate features shipped this session with exactly these shapes, each
# of which reads as complete in review and does nothing in the app:
#
#   showTooShortToast   set in two places, read in none — a recording too short
#                       to send was deleted in silence
#   transientError      four different failure messages written, none displayed
#   applyLockedStop     the transition the stop button needed, called only from
#                       its own test, so the suite stayed green
#   didConfirmRecent…   the method that sends a multiple selection, called from
#                       nowhere, so the selection could never be sent
#
# A test of the type in isolation passes in every one of those cases. What is
# missing is a caller or a reader, which is a property of the whole tree.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
exec /usr/bin/env python3 Scripts/check_unread_state.py

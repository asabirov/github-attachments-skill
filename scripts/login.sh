#!/usr/bin/env bash
# The one thing here a human has to do, and it is done once.
#
# Only the browser drivers need this. A token upload needs no sign-in at all, so run
# this when there is no `gh` login and no broker to reach one. The browser route
# authenticates with a session cookie and a CSRF token, and no script can create one —
# that is a password and a second factor.
#
# This opens a visible Chrome against the profile this skill owns. Sign in, close the
# window, and every later run is headless and unattended until the session expires.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec node "$here/scripts/drivers/chrome.mjs" "" "" 0 --login

#!/usr/bin/env bash
# Turn a local image into a GitHub attachment URL.
#
#   mint.sh <image> --repo <owner/name> [--alt TEXT] [--format url|markdown|html]
#           [--driver auto|token|orca|chrome] [--timeout SECONDS]
#
# Takes a path and prints a URL. It never accepts image bytes and never prints them,
# because in an agent harness the signature is the cost model: a 400 KB screenshot is
# 550 KB of base64, and putting that through a conversation costs six figures of tokens
# to achieve what passing a path achieves for nothing.
#
# The URL is bound to the repository you name, captured at upload time. Mint against one
# repo and embed in another and the image renders for you and 404s for your reader.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

image=""; repo=""; alt=""; format="url"; driver="auto"; timeout_s=60

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)    repo="$2"; shift 2 ;;
		--alt)     alt="$2"; shift 2 ;;
		--format)  format="$2"; shift 2 ;;
		--driver)  driver="$2"; shift 2 ;;
		--timeout) timeout_s="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		-*)        echo "mint: unknown flag $1" >&2; exit 2 ;;
		*)         image="$1"; shift ;;
	esac
done

[ -n "$image" ] || { usage >&2; exit 2; }
[ -n "$repo" ]  || { echo "mint: --repo <owner/name> is required, and decides who can see the image" >&2; exit 2; }
[ -f "$image" ] || { echo "mint: no such file: $image" >&2; exit 2; }

case "$repo" in
	*/*) ;;
	*) echo "mint: --repo wants owner/name, got '$repo'" >&2; exit 2 ;;
esac

# GitHub's token upload refuses PDFs outright, and documents belong in a document
# store, not in an issue body. Refused here so no browser ever starts for one.
#
# The name is asked first and the file's own first bytes second, because letting one
# through is not a harmless no-op: GitHub takes the upload and returns a files/ URL
# this skill no longer reads, so the caller pays the whole transfer and then waits
# out --timeout for a URL that is never coming.
#
# Those bytes are compared as hex, not as text. A JPEG and a WebP both carry a null
# byte inside their first five, and a command substitution holding one makes bash
# warn on stderr -- on every successful upload of an image that was never in doubt.
is_pdf=false
case "$image" in *.[pP][dD][fF]) is_pdf=true ;; esac
if [ "$(head -c 5 "$image" | od -A n -t x1 | tr -d ' \n')" = "255044462d" ]; then is_pdf=true; fi
if $is_pdf; then
	echo "mint: $image is a PDF, and this skill uploads images only; keep documents in a document store and link to them" >&2
	exit 2
fi

# GitHub refuses images over 10 MB, and it refuses them after the upload rather than
# before, which reads from here as a mysterious timeout.
bytes="$(wc -c < "$image" | tr -d ' ')"
if [ "$bytes" -gt 10485760 ]; then
	echo "mint: $image is $((bytes / 1048576)) MB; GitHub's attachment limit is 10 MB" >&2
	exit 2
fi

# A token upload comes first: one request, no browser, and the only path open on a
# host with no display. Exit 9 from that driver means there is no token path here,
# or none for this file, and a browser is the answer rather than an error.
minted=false
if [ "$driver" = auto ]; then
	why="$(mktemp)"; trap 'rm -f "$why"' EXIT
	status=0
	attachment="$(node "$here/scripts/drivers/token.mjs" "$image" "$repo" "$timeout_s" 2>"$why")" || status=$?
	# Only "there is no token path here" is held back, because in `auto` it is not
	# news. Anything else that driver said belongs on stderr, uploaded or not.
	[ "$status" = 9 ] || cat "$why" >&2
	case "$status" in
		0) minted=true ;;
		# Orca's browser is already signed in, so it costs nobody a login. The Chrome
		# driver is what makes this work when Orca is closed, and it is the one that
		# needs `login.sh` first.
		9) if [ -n "${ORCA_WORKTREE_ID:-}" ] && command -v orca >/dev/null 2>&1; then
				driver=orca
			else
				driver=chrome
			fi ;;
		*) exit "$status" ;;
	esac
fi

if ! $minted; then
	case "$driver" in
		token)  attachment="$(node "$here/scripts/drivers/token.mjs" "$image" "$repo" "$timeout_s")" ;;
		orca)   attachment="$("$here/scripts/drivers/orca.sh" "$image" "$repo" "$timeout_s")" ;;
		chrome) attachment="$(node "$here/scripts/drivers/chrome.mjs" "$image" "$repo" "$timeout_s")" ;;
		*)      echo "mint: --driver wants auto, token, orca or chrome" >&2; exit 2 ;;
	esac
fi

case "$attachment" in
    https://github.com/user-attachments/*) url="$attachment" ;;
    *) url="https://github.com/user-attachments/assets/$attachment" ;;
esac
[ -n "$alt" ] || alt="$(basename "${image%.*}")"

case "$format" in
	url)      printf '%s\n' "$url" ;;
	markdown) printf '![%s](%s)\n' "$alt" "$url" ;;
	html)     printf '<img alt="%s" src="%s" />\n' "$alt" "$url" ;;
	*)        echo "mint: --format wants url, markdown or html" >&2; exit 2 ;;
esac

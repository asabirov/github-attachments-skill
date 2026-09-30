#!/usr/bin/env bash
# Turn a local image into a GitHub attachment URL.
#
#   mint.sh <image> --repo <owner/name> [--alt TEXT] [--format url|markdown|html]
#           [--driver auto|token] [--timeout SECONDS]
#
# A path in, a URL out: never image bytes, in either direction. The URL is bound to the
# repository you name, captured at upload time. SKILL.md has both reasons.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

image=""; repo=""; alt=""; format="url"; driver="auto"; timeout_s=60

# The header block is the help text, so it stops at the first line that is not a
# comment rather than at a line number an edit can move.
usage() { awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

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
# Before the PDF check below, which is the first thing to touch the bytes and would
# otherwise leave bash's own `Permission denied` and exit 1.
[ -r "$image" ] || { echo "mint: cannot read $image; check its permissions" >&2; exit 2; }

# One slash, both parts non-empty, and no path segments: this string is sent to a
# broker that resolves it, so `..` must never survive the check.
case "$repo" in
	*/*/*|/*|*/|*..*|"") echo "mint: --repo wants owner/name, got '$repo'" >&2; exit 2 ;;
	*/*) ;;
	*) echo "mint: --repo wants owner/name, got '$repo'" >&2; exit 2 ;;
esac

# Bounded at both ends, because a driver hands this straight to Node: `0` is not a
# wait, and a number too big for a double arrives there as Infinity. Length is tested
# first so bash is never asked to compare a 400-digit number.
bad_timeout() { echo "mint: --timeout wants 1 to 3600 whole seconds, got '${timeout_s:0:20}'" >&2; exit 2; }
case "$timeout_s" in ''|*[!0-9]*|?????*) bad_timeout ;; esac
[ "$timeout_s" -ge 1 ] && [ "$timeout_s" -le 3600 ] || bad_timeout

# GitHub's token upload refuses PDFs outright, and documents belong in a document
# store, not in an issue body. Refused here so no byte of one is ever uploaded.
#
# The name is asked first and the file's own first bytes second. Those bytes are
# compared as hex, not as text: a JPEG and a WebP both carry a null byte inside their
# first five, and a command substitution holding one makes bash warn on stderr -- on
# every successful upload of an image that was never in doubt.
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

# One driver, and it opens no browser. Exit 9 was the cue to start one; it now means
# this machine has no token upload for this file, which is the end of the road.
case "$driver" in
	auto|token)  attachment="$(node "$here/scripts/drivers/token.mjs" "$image" "$repo" "$timeout_s")" ;;
	chrome|orca) echo "mint: the $driver browser driver was removed; this skill uploads with a token, so give this machine a gh login or the broker's gh-mint" >&2; exit 2 ;;
	*)           echo "mint: --driver wants auto or token" >&2; exit 2 ;;
esac

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

#!/usr/bin/env bash
# Upload with a GitHub token. A machine with a gh login uploads the bytes
# itself; one without runs gh-mint, which hands them to the broker on the
# machine that holds the token. Exit codes are in SKILL.md.
#
# The upload itself is one curl request, so this driver needs Bash and curl,
# never Node.js. The token is read from gh and handed to curl on stdin through
# `curl --config -`; it is never in argv, in a message or in a log.

set -euo pipefail
LC_ALL=C
export LC_ALL

image="${1:?}"
repo="${2:?}"
timeout_s="${3:-60}"

UPLOAD='https://uploads.github.com/user-attachments/assets'
# The URL is matched on its whole shape: 36 characters, each a hex digit or `-`.
ASSET='^https://github\.com/user-attachments/assets/[0-9a-fA-F-]{36}$'
QUOTED_ASSET='"https://github\.com/user-attachments/assets/[0-9a-fA-F-]{36}"'

# printf, not echo: a message is one write, so it cannot be split by a signal.
fail() { # fail <code> <message...>
	local code="$1"; shift
	printf 'token: %s\n' "$*" >&2
	exit "$code"
}
print_url() { printf '%s\n' "$1"; exit 0; }

# One line, 200 characters: the body's whitespace collapses for the message.
oneline() {
	printf '%s' "${1:-}" | tr '\n\t\r' '   ' | tr -s ' ' | sed 's/^ //;s/ $//' | cut -c1-200
}

# URLSearchParams encoding: space becomes +, `* - . _` and letters and digits
# stay, every other byte becomes %XX. The upload's query carries the name and
# the content type, so they must be percent-encoded exactly as the endpoint
# expects them.
urlsearch() {
	printf '%s' "$1" | while IFS= read -r -n 1 c; do
		case "$c" in
			[A-Za-z0-9.*_-]) printf '%s' "$c" ;;
			' ') printf '+' ;;
			*) printf '%%%02X' "'$c" ;;
		esac
	done
}

# One deadline for the whole run, from --timeout. `date +%s` is the portable
# part, and the budget is whole seconds, so left() is whole seconds too.
budget="$timeout_s"
case "$budget" in ''|*[!0-9]*) budget=60 ;; esac
[ "$budget" = 0 ] && budget=60
[ "$budget" -gt 3600 ] && budget=3600
[ "$budget" -lt 1 ] && budget=1
deadline=$(( $(date +%s) + budget ))
left() { # left -> seconds until the deadline, never below 0
	local now rem
	now=$(date +%s)
	rem=$(( deadline - now ))
	[ "$rem" -lt 0 ] && rem=0
	printf '%s' "$rem"
}

# Run a command in the background with a watchdog that enforces the run's one
# deadline, but never below <min_seconds>. macOS has no `timeout` command, so
# this is the portable shape. The command's stdout and stderr go to private
# temp files, never a pipe, and the watchdog's stdio is /dev/null so its sleep
# cannot keep a caller's pipe open. Sets TIMED_RC, TIMED_KILLED, TIMED_OUT, and
# leaves the command's stderr in timed_err_file (verbatim, trailing newlines
# kept) for the caller to print or drop. A command the deadline ends reads back
# as exit 143, which is TIMED_KILLED.
timed_err_file=''
run_timed() { # run_timed <min_seconds> -- <command...>
	local min_sec="$1"; shift
	local out seconds pid w rc
	[ -n "$timed_err_file" ] && rm -f "$timed_err_file"
	timed_err_file="$(mktemp)"
	out="$(mktemp)"
	seconds="$(left)"
	[ "$seconds" -lt "$min_sec" ] && seconds="$min_sec"
	"$@" >"$out" 2>"$timed_err_file" </dev/null &
	pid=$!
	(
		trap 'kill "${s:-}" 2>/dev/null; exit 0' TERM
		sleep "$seconds" &
		s=$!
		wait "$s"
		kill -TERM "$pid" 2>/dev/null
	) </dev/null >/dev/null 2>&1 &
	w=$!
	rc=0
	wait "$pid" 2>/dev/null || rc=$?
	kill -TERM "$w" 2>/dev/null || true
	wait "$w" 2>/dev/null || true
	TIMED_RC=$rc
	if [ "$rc" -eq 143 ]; then TIMED_KILLED=1; else TIMED_KILLED=0; fi
	TIMED_OUT="$(cat "$out" 2>/dev/null || true)"
	rm -f "$out"
}

# The name and the content type travel together in the upload's query, so the
# extension decides the type rather than the bytes.
base="${image##*/}"
ext=''
case "$base" in
	.*) ;;
	*.*) ext=".${base##*.}" ;;
esac
ext_lc="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
type=''
case "$ext_lc" in
	.png) type='image/png' ;;
	.jpg|.jpeg) type='image/jpeg' ;;
	.gif) type='image/gif' ;;
	.webp) type='image/webp' ;;
esac
[ -n "$type" ] || fail 9 "$base is not a PNG, JPEG, GIF or WebP"

# Read the bytes once into a private copy: a symlink named x.png can point at
# anything, and a swap cannot change the bytes between the check and the upload
# when both see the same private file. The copy is removed on every exit.
copy="$(mktemp)"
tmp_clean() { rm -f "${copy:-}" "${timed_err_file:-}"; }
trap tmp_clean EXIT
chmod 600 "$copy"
if ! cp "$image" "$copy" 2>/dev/null; then
	fail 2 "cannot read $image: could not copy the file"
fi

size="$(wc -c < "$copy" | tr -d ' ')"
if [ "$size" -gt 10485760 ]; then
	fail 2 "$base is over GitHub's 10 MB limit"
fi

# Byte offsets each type must match, checked against the copy about to be
# uploaded. WebP needs WEBP at offset 8 as well, or any RIFF container passes.
magic_at() { # magic_at <offset> <count> -> lowercase hex, no spaces
	dd if="$copy" bs=1 skip="$1" count="$2" 2>/dev/null | od -A n -t x1 | tr -d ' \n'
}
magic_ok() {
	case "$type" in
		image/png)  [ "$(magic_at 0 4)" = '89504e47' ] ;;
		image/jpeg) [ "$(magic_at 0 3)" = 'ffd8ff' ] ;;
		image/gif)  [ "$(magic_at 0 4)" = '47494638' ] ;;
		image/webp) [ "$(magic_at 0 4)" = '52494646' ] && [ "$(magic_at 8 4)" = '57454250' ] ;;
		*) return 1 ;;
	esac
}
if ! magic_ok; then
	fail 2 "$base is named $ext but its bytes are not $type"
fi

# Asking gh is what picks the path. gh's own stderr is never quoted: it can
# carry a token, so run_timed keeps it in timed_err_file and nothing prints it.
run_timed 0 gh auth token --hostname github.com
token=''
if [ "$TIMED_RC" -eq 0 ]; then token="$TIMED_OUT"; fi

if [ -z "$token" ]; then
	# The broker reads the body under a 30s deadline and then caps the mint at
	# 90s, so gh-mint waits up to 150s. Killing it at --timeout would report 7
	# for an upload still in flight, and the retry would duplicate the asset.
	if ! command -v gh-mint >/dev/null 2>&1; then
		fail 9 "no gh login or gh-mint; run \`gh auth login\` or set up the broker's \`gh-mint\`"
	fi
	run_timed 150 gh-mint "$image" --repo "$repo"
	# gh-mint's stderr passes through: it names the refusal, never a token.
	if [ -s "$timed_err_file" ]; then cat "$timed_err_file" >&2; fi
	rm -f "$timed_err_file"; timed_err_file=''
	mint_url="$(printf '%s' "$TIMED_OUT" | tr -d '\r' | sed 's/[[:space:]]*$//')"
	if [ "$TIMED_KILLED" -eq 0 ] && [ "$TIMED_RC" -eq 0 ] \
		&& printf '%s' "$mint_url" | grep -Eq "$ASSET"; then
		print_url "$mint_url"
	fi
	# The broker's exit says whether anything reached GitHub. 64 and 77 are
	# refusals before sending, and 75 means nothing was stored: nothing sent,
	# or GitHub answered 4xx. 76 means the bytes may be on GitHub (its 90s cap,
	# a dropped connection, a 5xx, a 2xx with no URL), and so does any code this
	# does not know, and so does a gh-mint killed by the watchdog.
	if [ "$TIMED_KILLED" -eq 1 ]; then
		fail 7 'gh-mint failed: ETIMEDOUT'
	fi
	if [ "$TIMED_RC" -eq 64 ]; then
		fail 2 'gh-mint refused the file; see its message above'
	fi
	case "$TIMED_RC" in
		75) fail 8 'gh-mint exited 75 without an attachment URL; nothing was stored, so a retry is safe' ;;
		76) fail 7 'gh-mint exited 76 without an attachment URL; the image may already be on GitHub, so check before minting it again' ;;
		77) fail 8 'gh-mint exited 77 without an attachment URL' ;;
		*)  fail 7 "gh-mint exited $TIMED_RC without an attachment URL" ;;
	esac
fi

# The asset is bound to this id at upload time, so --repo must name the
# repository the link will be used in. gh's own stderr is never quoted.
run_timed 0 gh api "repos/$repo" --jq '.id'
id="$(printf '%s' "$TIMED_OUT" | tr -d '\r\n')"
if ! printf '%s' "$id" | grep -Eq '^[0-9]+$'; then
	fail 8 "cannot read the id of $repo; check the name and that this login can see it"
fi

# curl sends the copy, never the path mint.sh looked at, with the token on
# stdin rather than argv. No -L: a redirect would re-send the token. curl's
# own stderr is the reason on failure, and carries no token.
body_file="$(mktemp)"; curl_err="$(mktemp)"; status_file="$(mktemp)"
remain="$(left)"
if [ "$remain" -le 0 ]; then maxtime='0.001'; else maxtime="$remain"; fi
query="name=$(urlsearch "$base")&content_type=$(urlsearch "$type")&repository_id=$id"
curl_rc=0
curl --silent --show-error --max-time "$maxtime" \
	--config - \
	--data-binary @"$copy" \
	-H "Content-Type: $type" \
	-H 'Accept: application/vnd.github+json' \
	-o "$body_file" \
	-w '%{http_code}' \
	"$UPLOAD?$query" >"$status_file" 2>"$curl_err" <<CONFIG || curl_rc=$?
header = "Authorization: token $token"
CONFIG
status="$(cat "$status_file" 2>/dev/null || true)"
body="$(cat "$body_file" 2>/dev/null || true)"
curl_err_text="$(cat "$curl_err" 2>/dev/null || true)"
rm -f "$body_file" "$curl_err" "$status_file"

if [ "$curl_rc" -ne 0 ]; then
	# 6 and 7 mean nothing was sent; every other failure may have reached GitHub.
	reason="$(printf '%s' "$curl_err_text" | sed -n '1p' | tr -d '\r')"
	[ -n "$reason" ] || reason="curl exited $curl_rc"
	case "$curl_rc" in
		6|7) fail 8 "the upload did not complete: $reason" ;;
		*)   fail 7 "the upload did not complete: $reason" ;;
	esac
fi

case "$status" in
	2*)
		# The field holding it is undocumented, so the URL is matched on its
		# shape, as a whole JSON string value.
		url="$(printf '%s' "$body" | grep -Eo -m 1 "$QUOTED_ASSET" | tr -d '"' || true)"
		[ -n "$url" ] || fail 7 "the upload answered HTTP $status without an attachment URL"
		print_url "$url"
		;;
	5*) fail 7 "GitHub answered HTTP $status $(oneline "$body")" ;;
	*)  fail 8 "GitHub answered HTTP $status $(oneline "$body")" ;;
esac

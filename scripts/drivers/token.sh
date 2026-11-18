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

# Every temp file is tracked, and INT, TERM and HUP clean them all and kill
# every child first. A signal mid-upload must not leave the token's temp file
# or a live curl, so the handler kills the background jobs before it removes
# the files. track records a path; cleanup is the one place that removes them.
# The paths live in a Bash array, not one space-joined string, so a path that
# holds a space (a TMPDIR with a space) still resolves as one element. The
# length guard keeps `set -u` quiet on Bash 3.2, where an empty array expansion
# is an unbound variable.
TMPFILES=()
track() { # track <path...> — record temp files for cleanup on every exit
	TMPFILES+=("$@")
}
tmp_clean() { # remove every tracked temp file
	local i
	for ((i = 0; i < ${#TMPFILES[@]}; i++)); do
		rm -f "${TMPFILES[$i]}" 2>/dev/null
	done
	TMPFILES=()
}
cleanup() { # one handler for EXIT, INT, TERM and HUP
	kill -TERM $(jobs -p) 2>/dev/null || true
	wait 2>/dev/null || true
	tmp_clean
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

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

# Parse the upload answer the way the old driver did: JSON.parse, then the
# first top-level string value whose whole shape is an asset URL. A recursive
# descent reader in awk accepts only real JSON (object, array, string, number,
# true, false and null), so trailing text, a trailing comma, a bare key, a
# missing colon, a bad escape or a raw control character in a string all
# refuse the body the way JSON.parse does. It unescapes \/ and prints one
# top-level string value per line; exit 1 means malformed JSON, which the
# caller maps to the same exit 7 refusal as a missing URL.
json_top_strings() {
	awk '
		function ws(    c) {
			while (pos <= length(json)) {
				c = substr(json, pos, 1)
				if (c == " " || c == "\t" || c == "\n" || c == "\r") pos++
				else return
			}
		}
		function hexval(c) {
			if (c >= "0" && c <= "9") return index("0123456789", c) - 1
			return index("abcdef", tolower(c)) + 9
		}
		function is_hex(s,    i, c) {
			for (i = 1; i <= 4; i++) {
				c = substr(s, i, 1)
				if (!((c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F"))) return 0
			}
			return 1
		}
		function parse_string(    c, e, u, v) {
			sval = ""
			pos++
			while (pos <= length(json)) {
				c = substr(json, pos, 1); pos++
				if (c == "\"") return 1
				if (c == "\\") {
					if (pos > length(json)) { err = 1; return 0 }
					e = substr(json, pos, 1); pos++
					if (e == "\"") sval = sval "\""
					else if (e == "\\") sval = sval "\\"
					else if (e == "/") sval = sval "/"
					else if (e == "b") sval = sval "\b"
					else if (e == "f") sval = sval "\f"
					else if (e == "n") sval = sval "\n"
					else if (e == "r") sval = sval "\r"
					else if (e == "t") sval = sval "\t"
					else if (e == "u") {
						if (pos + 3 > length(json)) { err = 1; return 0 }
						u = substr(json, pos, 4)
						if (!is_hex(u)) { err = 1; return 0 }
						pos += 4
						v = hexval(substr(u, 1, 1)) * 4096 + hexval(substr(u, 2, 1)) * 256 + hexval(substr(u, 3, 1)) * 16 + hexval(substr(u, 4, 1))
						if (v == 0) sval = sval "?"
						else if (v <= 127) sval = sval sprintf("%c", v)
						else sval = sval "?"
					}
					else { err = 1; return 0 }
					continue
				}
				if (c < " ") { err = 1; return 0 }
				sval = sval c
			}
			err = 1; return 0
		}
		function parse_number(    c) {
			c = substr(json, pos, 1)
			if (c == "-") {
				pos++
				if (pos > length(json)) { err = 1; return 0 }
				c = substr(json, pos, 1)
				if (!(c >= "0" && c <= "9")) { err = 1; return 0 }
			}
			if (c == "0") pos++
			else if (c >= "1" && c <= "9") {
				pos++
				while (pos <= length(json)) {
					c = substr(json, pos, 1)
					if (c >= "0" && c <= "9") pos++; else break
				}
			} else { err = 1; return 0 }
			if (pos <= length(json) && substr(json, pos, 1) == ".") {
				pos++
				if (pos > length(json) || !(substr(json, pos, 1) >= "0" && substr(json, pos, 1) <= "9")) { err = 1; return 0 }
				while (pos <= length(json)) {
					c = substr(json, pos, 1)
					if (c >= "0" && c <= "9") pos++; else break
				}
			}
			if (pos <= length(json)) {
				c = substr(json, pos, 1)
				if (c == "e" || c == "E") {
					pos++
					if (pos > length(json)) { err = 1; return 0 }
					c = substr(json, pos, 1)
					if (c == "+" || c == "-") {
						pos++
						if (pos > length(json)) { err = 1; return 0 }
						c = substr(json, pos, 1)
					}
					if (!(c >= "0" && c <= "9")) { err = 1; return 0 }
					while (pos <= length(json)) {
						c = substr(json, pos, 1)
						if (c >= "0" && c <= "9") pos++; else break
					}
				}
			}
			return 1
		}
		function parse_literal() {
			if (substr(json, pos, 4) == "true") { pos += 4; return 1 }
			if (substr(json, pos, 5) == "false") { pos += 5; return 1 }
			if (substr(json, pos, 4) == "null") { pos += 4; return 1 }
			err = 1; return 0
		}
		function parse_object(depth,    c) {
			pos++
			ws()
			if (pos > length(json)) { err = 1; return 0 }
			if (substr(json, pos, 1) == "}") { pos++; return 1 }
			while (1) {
				ws()
				if (pos > length(json)) { err = 1; return 0 }
				if (substr(json, pos, 1) != "\"") { err = 1; return 0 }
				if (!parse_string()) return 0
				ws()
				if (pos > length(json) || substr(json, pos, 1) != ":") { err = 1; return 0 }
				pos++
				if (!parse_value(depth + 1)) return 0
				ws()
				if (pos > length(json)) { err = 1; return 0 }
				c = substr(json, pos, 1)
				if (c == ",") {
					pos++
					ws()
					if (pos > length(json) || substr(json, pos, 1) == "}") { err = 1; return 0 }
					continue
				}
				if (c == "}") { pos++; return 1 }
				err = 1; return 0
			}
		}
		function parse_array(depth,    c) {
			pos++
			ws()
			if (pos > length(json)) { err = 1; return 0 }
			if (substr(json, pos, 1) == "]") { pos++; return 1 }
			while (1) {
				if (!parse_value(depth + 1)) return 0
				ws()
				if (pos > length(json)) { err = 1; return 0 }
				c = substr(json, pos, 1)
				if (c == ",") {
					pos++
					ws()
					if (pos > length(json) || substr(json, pos, 1) == "]") { err = 1; return 0 }
					continue
				}
				if (c == "]") { pos++; return 1 }
				err = 1; return 0
			}
		}
		function parse_value(depth,    c) {
			ws()
			if (pos > length(json)) { err = 1; return 0 }
			c = substr(json, pos, 1)
			if (c == "{") return parse_object(depth)
			if (c == "[") return parse_array(depth)
			if (c == "\"") {
				if (!parse_string()) return 0
				if (depth == 1) { n++; vals[n] = sval }
				return 1
			}
			if (c == "-" || (c >= "0" && c <= "9")) return parse_number()
			if (c == "t" || c == "f" || c == "n") return parse_literal()
			err = 1; return 0
		}
		BEGIN {
			json = ""
			while ((getline line) > 0) json = json line "\n"
			pos = 1; err = 0; n = 0
			parse_value(0)
			if (!err) {
				ws()
				if (pos <= length(json)) err = 1
			}
			if (err) exit 1
			for (j = 1; j <= n; j++) print vals[j]
			exit 0
		}
	'
}

# One deadline for the whole run, from --timeout. `date +%s` is the portable
# part, and the budget is whole seconds, so left() is whole seconds too.
budget="$timeout_s"
case "$budget" in ''|*[!0-9]*) budget=60 ;; esac
budget=$((10#$budget))
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
	timed_err_file="$(mktemp)"; track "$timed_err_file"
	out="$(mktemp)"; track "$out"
	seconds="$(left)"
	[ "$seconds" -lt "$min_sec" ] && seconds="$min_sec"
	"$@" >"$out" 2>"$timed_err_file" </dev/null &
	pid=$!
	(
		# The trap kills the pending sleep through the job table, so a TERM
		# that lands before or after `sleep &` cannot leave the sleep alive.
		trap 'kill -TERM $(jobs -p) 2>/dev/null || true; wait 2>/dev/null || true; exit 0' TERM
		sleep "$seconds" &
		wait
		kill -TERM "$pid" 2>/dev/null || true
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
	*.*) ext=".${base##*.}" ;;
esac
# A dotfile such as .png has no extension, as Node's extname says: its only
# dot is the first character. .shot.png keeps its .png.
[ "$base" = "$ext" ] && ext=''
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
copy="$(mktemp)"; track "$copy"
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
body_file="$(mktemp)"; curl_err="$(mktemp)"; status_file="$(mktemp)"; track "$body_file" "$curl_err" "$status_file"
remain="$(left)"
if [ "$remain" -le 0 ]; then maxtime='0.001'; else maxtime="$remain"; fi
query="name=$(urlsearch "$base")&content_type=$(urlsearch "$type")&repository_id=$id"
curl_rc=0
# -q first: a .curlrc could record or forward the token, or add -L. curl runs
# as a tracked background job so a signal can kill it too.
curl -q --silent --show-error --max-time "$maxtime" \
	--config - \
	--data-binary @"$copy" \
	-H "Content-Type: $type" \
	-H 'Accept: application/vnd.github+json' \
	-o "$body_file" \
	-w '%{http_code}' \
	"$UPLOAD?$query" >"$status_file" 2>"$curl_err" <<CONFIG &
header = "Authorization: token $token"
CONFIG
curl_pid=$!
wait "$curl_pid" || curl_rc=$?
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
		# Parse like the old driver: read top-level JSON string values only,
		# unescape \/, and take the first whose whole shape is an asset URL.
		# Malformed JSON is the same refusal: exit 7, one message.
		top_values=''
		top_rc=0
		top_values="$(printf '%s' "$body" | json_top_strings)" || top_rc=$?
		if [ "$top_rc" -ne 0 ]; then
			fail 7 "the upload answered HTTP $status without an attachment URL"
		fi
		url="$(printf '%s' "$top_values" | grep -Em 1 "$ASSET" || true)"
		[ -n "$url" ] || fail 7 "the upload answered HTTP $status without an attachment URL"
		print_url "$url"
		;;
	5*) fail 7 "GitHub answered HTTP $status $(oneline "$body")" ;;
	*)  fail 8 "GitHub answered HTTP $status $(oneline "$body")" ;;
esac

#!/usr/bin/env bash
# What mint.sh refuses, how fast, and how the upload maps gh-mint's exit and
# curl's answer. Every case here is refused before anything is uploaded, or
# meets a fake gh, gh-mint and curl. That is the point: a bad --repo or a 12 MB
# file should cost nothing, and the failure that actually hurt in testing was
# an over-size image that uploaded for a minute and then timed out, because
# GitHub rejects on size after the transfer rather than before it.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mint="$here/scripts/mint.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0
check() { # check <name> <expected-exit> <expected-substring> -- cmd...
	local name="$1" want="$2" needle="$3"; shift 4
	local out; out="$("$@" 2>&1)"; local got=$?
	# No pipe. `printf | grep -q` reads a pipeline's status under `set -o pipefail`,
	# and grep exits the moment it matches -- so printf can take EPIPE on a long
	# enough output and fail a check whose exit code and text were both right. The
	# outputs here are short, and 140 runs (60 idle, 80 under load) did not produce
	# it, so this is the shape being removed rather than a failure being fixed. It
	# also drops the `--` guard: half these expectations start with a dash and grep
	# would have read them as its own flags, which `==` never does.
	if [ "$got" = "$want" ] && [[ "$out" == *"$needle"* ]]; then
		pass=$((pass + 1)); printf 'ok   %s\n' "$name"
	else
		fail=$((fail + 1)); printf 'FAIL %s (exit %s, wanted %s)\n     %s\n' "$name" "$got" "$want" "$out"
	fi
}
check_line() { # check_line <name> <expected-exit> <expected-exact-line> -- cmd...
	local name="$1" want="$2" needle="$3"; shift 4
	local out; out="$("$@" 2>&1)"; local got=$?
	if [ "$got" = "$want" ] && [ "$out" = "$needle" ]; then
		pass=$((pass + 1)); printf 'ok   %s\n' "$name"
	else
		fail=$((fail + 1)); printf 'FAIL %s (exit %s, wanted %s)\n     %s\n' "$name" "$got" "$want" "$out"
	fi
}

printf 'x' > "$tmp/tiny.png"

check "no arguments prints usage"        2 "mint.sh <image>"     -- "$mint"
check "missing --repo is named"          2 "--repo <owner/name>" -- "$mint" "$tmp/tiny.png"
check "missing file is named"            2 "no such file"        -- "$mint" "$tmp/absent.png" --repo a/b
check "bare repo name is refused"        2 "wants owner/name"    -- "$mint" "$tmp/tiny.png" --repo notaslug
check "unknown flag is refused"          2 "unknown flag"        -- "$mint" "$tmp/tiny.png" --repo a/b --nope
check "a removed browser driver is named" 2 "browser driver was removed" -- "$mint" "$tmp/tiny.png" --repo a/b --driver chrome
check "an unknown driver is refused"      2 "wants auto or token" -- "$mint" "$tmp/tiny.png" --repo a/b --driver ie6

# A value flag with nothing after it. Each one used to read an unset "$2" under `set -u`
# and exit 1 with bash's own message, which told the caller nothing about the flag.
for flag in --repo --alt --format --driver --timeout; do
	check "$flag with no value is refused" 2 "mint: $flag needs a value" -- "$mint" "$tmp/tiny.png" "$flag"
done

# Images only, and refused before the upload: GitHub would accept a PDF and hand back a
# files/ URL this skill no longer reads, so the caller would pay the transfer and then
# time out. Both the name and the file's own first bytes are asked.
printf 'x' > "$tmp/homework.pdf"; printf 'x' > "$tmp/HOMEWORK.PDF"
printf '%%PDF-1.7\n1 0 obj\n' > "$tmp/homework"
check "a PDF is refused early"           2 "uploads images only" -- "$mint" "$tmp/homework.pdf" --repo a/b
check "an uppercase .PDF is refused"     2 "uploads images only" -- "$mint" "$tmp/HOMEWORK.PDF" --repo a/b
check "a PDF without a suffix is caught" 2 "uploads images only" -- "$mint" "$tmp/homework" --repo a/b

# A name that is not PNG, JPEG, GIF or WebP is exit 9, not a byte check: it has no
# content type to upload.
printf 'x' > "$tmp/notes.txt"
check "a non-image name is refused"      9 "is not a PNG, JPEG, GIF or WebP" -- "$mint" "$tmp/notes.txt" --repo a/b

# An unreadable file is refused before any byte is touched.
printf 'x' > "$tmp/unreadable.png"
chmod 000 "$tmp/unreadable.png"
check "an unreadable file is refused"    2 "cannot read" -- "$mint" "$tmp/unreadable.png" --repo a/b

# The name picks the type, and the bytes must agree. A symlink named x.png can point
# at anything, so the check reads through it.
printf 'not a png' > "$tmp/fake.png"
printf 'not a png' > "$tmp/note"
ln -s "$tmp/note" "$tmp/link.png"
check "bytes that do not match the name are refused" 2 "its bytes are not image/png" -- "$mint" "$tmp/fake.png" --repo a/b
check "a symlink named .png cannot publish other bytes" 2 "its bytes are not image/png" -- "$mint" "$tmp/link.png" --repo a/b

# WebP needs WEBP at offset 8 as well, or any RIFF container would pass.
printf '\x52\x49\x46\x46\x00\x00\x00\x00XXXX' > "$tmp/riff.webp"
check "a webp without WEBP at offset 8 is refused" 2 "its bytes are not image/webp" -- "$mint" "$tmp/riff.webp" --repo a/b

# 11 MB, over GitHub's 10 MB ceiling, and refused without a byte going out.
mkfile_size=$((11 * 1024 * 1024))
dd if=/dev/zero of="$tmp/huge.png" bs=1024 count=$((mkfile_size / 1024)) 2>/dev/null
check "oversize image is refused early"  2 "limit is 10 MB"      -- "$mint" "$tmp/huge.png" --repo a/b

# The broker's mint says whether a retry is safe, and the exit code has to keep that.
# A fake gh with no login sends the upload to a fake gh-mint that exits with $MINT_EXIT;
# a fake gh with a login sends it to a fake curl that answers with $CURL_STATUS,
# $CURL_BODY and $CURL_EXIT. All three live in a shared cache and are written only when
# their content changes, so a repeat run adds no new executable file.
fakebin="$here/tests/.fakes"
mkdir -p "$fakebin"
write_once() { # write_once <dir> <name> <content>
	local dir="$1" name="$2" content="$3"
	local f="$dir/$name"
	# Compare exact bytes: `$(cat ...)` would strip trailing newlines, but the
	# supplied bodies keep theirs, which rewrites both files on every run.
	if [ ! -e "$f" ] || ! printf '%s' "$content" | cmp -s - "$f"; then
		printf '%s' "$content" > "$f.tmp.$$"
		chmod +x "$f.tmp.$$"
		mv "$f.tmp.$$" "$f"
	fi
}
write_once "$fakebin" gh '#!/bin/sh
if [ "${GH_AUTH:-0}" != "1" ]; then exit 1; fi
case "$1" in
  auth) echo "${GH_TOKEN_OUT:-fake-token}" ;;
  api) echo "${GH_ID_OUT:-42}" ;;
  *) exit 1 ;;
esac
'
write_once "$fakebin" gh-mint '#!/bin/sh
echo "gh-mint: exit $MINT_EXIT" >&2
if [ "${MINT_EXIT:-0}" = "0" ]; then
  echo "https://github.com/user-attachments/assets/12345678-1234-4234-8234-1234567890ab"
fi
exit "${MINT_EXIT:-0}"
'
write_once "$fakebin" curl '#!/bin/sh
body="${CURL_BODY:-}"
status="${CURL_STATUS:-200}"
ec="${CURL_EXIT:-0}"
if [ "${CURL_REQUIRE_Q:-0}" = "1" ] && [ "${1:-}" != "-q" ]; then
  printf "curl: -q was not the first argument\n" >&2
  exit 99
fi
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
if [ -n "$out" ]; then printf "%s" "$body" > "$out"; fi
printf "%s" "$status"
if [ "$ec" != "0" ]; then printf "curl: (%s) fake error %s\n" "$ec" "$ec" >&2; fi
exit "$ec"
'
# A sleep that does not return on its own in time: the driver's watchdog must
# kill it, not wait on it, and its stdio must not keep mint.sh's own command
# substitution open. It self-limits so a broken cleanup cannot hang a run.
write_once "$fakebin" sleep '#!/bin/sh
if [ -n "${SLEEP_PID_FILE:-}" ]; then printf "%s\n" "$$" >> "$SLEEP_PID_FILE"; fi
exec /bin/sleep 10
'

# The fake commands shadow only what they replace; the rest of the PATH is the
# system's ordinary /usr/bin and /bin, without /usr/local/bin where the real gh
# and gh-mint shims live on this host. A second directory holds only gh, so the
# "no gh-mint" route is reachable.
fake_path="$fakebin:/usr/bin:/bin"
nogh="$fakebin/nogh"
mkdir -p "$nogh"
write_once "$nogh" gh '#!/bin/sh
exit 1
'
nogh_path="$nogh:/usr/bin:/bin"

# A curl that hangs, records its pid, and waits: the signal tests kill mint.sh
# mid-upload and then check that this process and every temp file are gone. It
# self-limits so a broken cleanup cannot hang a run.
signalbin="$fakebin/signal"
mkdir -p "$signalbin"
write_once "$signalbin" curl '#!/bin/sh
if [ -n "${SIGNAL_MARKER:-}" ]; then printf "%s\n" "$$" > "$SIGNAL_MARKER"; fi
exec /bin/sleep 10
'
signal_path="$signalbin:$fakebin:/usr/bin:/bin"

printf '\x89PNG\r\n\x1a\n' > "$tmp/real.png"
asset="https://github.com/user-attachments/assets/12345678-1234-4234-8234-1234567890ab"

check "mint 75, nothing stored, is safe to retry" 8 "a retry is safe" -- env PATH="$fake_path" MINT_EXIT=75 "$mint" "$tmp/real.png" --repo a/b
check "mint 76, maybe stored, is not"             7 "check before minting it again" -- env PATH="$fake_path" MINT_EXIT=76 "$mint" "$tmp/real.png" --repo a/b
check "mint 64 refuses the file"                  2 "refused the file" -- env PATH="$fake_path" MINT_EXIT=64 "$mint" "$tmp/real.png" --repo a/b
check "mint 77 refused, is safe to retry"         8 "exited 77 without an attachment URL" -- env PATH="$fake_path" MINT_EXIT=77 "$mint" "$tmp/real.png" --repo a/b
check "mint with another code may have stored"    7 "exited 42 without an attachment URL" -- env PATH="$fake_path" MINT_EXIT=42 "$mint" "$tmp/real.png" --repo a/b
check "mint 0 with a URL succeeds"                0 "$asset" -- env PATH="$fake_path" MINT_EXIT=0 "$mint" "$tmp/real.png" --repo a/b
check "no gh login and no gh-mint is exit 9"      9 "no gh login or gh-mint" -- env PATH="$nogh_path" "$mint" "$tmp/real.png" --repo a/b

check "a gh login with no repository id is refused" 8 "cannot read the id" -- env PATH="$fake_path" GH_AUTH=1 GH_ID_OUT=x "$mint" "$tmp/real.png" --repo a/b
check "curl 6, nothing sent, is safe to retry"      8 "the upload did not complete" -- env PATH="$fake_path" GH_AUTH=1 CURL_EXIT=6 "$mint" "$tmp/real.png" --repo a/b
check "curl 7, nothing sent, is safe to retry"      8 "the upload did not complete" -- env PATH="$fake_path" GH_AUTH=1 CURL_EXIT=7 "$mint" "$tmp/real.png" --repo a/b
check "curl 28, maybe sent, is not"                 7 "the upload did not complete" -- env PATH="$fake_path" GH_AUTH=1 CURL_EXIT=28 "$mint" "$tmp/real.png" --repo a/b
check "GitHub 500, maybe stored, is not"            7 "GitHub answered HTTP 500" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=500 CURL_BODY='{"message":"boom"}' "$mint" "$tmp/real.png" --repo a/b
check "GitHub 404, refused, is safe to retry"       8 "GitHub answered HTTP 404" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=404 CURL_BODY='{"message":"not found"}' "$mint" "$tmp/real.png" --repo a/b
check "GitHub 302, no attachment URL, is safe to retry" 8 "GitHub answered HTTP 302" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=302 "$mint" "$tmp/real.png" --repo a/b
check "2xx with no attachment URL is not safe"      7 "without an attachment URL" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY='{"nope":"x"}' "$mint" "$tmp/real.png" --repo a/b
check "a gh login uploads with curl"                0 "$asset" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{\"url\":\"$asset\"}" "$mint" "$tmp/real.png" --repo a/b

# The pending sleep must also be dead when mint.sh returns: the watchdog's
# TERM trap is what kills it, and removing that cleanup must fail this test.
pidfile="$tmp/sleeppids"; rm -f "$pidfile"
check "mint.sh returns while a long sleep is pending" 0 "$asset" -- env PATH="$fake_path" GH_AUTH=1 SLEEP_PID_FILE="$pidfile" CURL_STATUS=201 CURL_BODY="{\"url\":\"$asset\"}" "$mint" "$tmp/real.png" --repo a/b
leak=0
while IFS= read -r p; do
	[ -n "$p" ] && kill -0 "$p" 2>/dev/null && leak=1
done < "$pidfile"
if [ "$leak" -eq 0 ] && [ -s "$pidfile" ]; then
	pass=$((pass + 1)); printf 'ok   the pending sleep was killed\n'
else
	fail=$((fail + 1)); printf 'FAIL a pending sleep survived (or none was recorded)\n'
fi

# The upload answer is parsed like the old driver: top-level JSON string values
# only, escaped \/ unescaped, malformed JSON refused, and exactly one URL out.
check "an escaped attachment URL is parsed" 0 "$asset" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY='{"url":"https:\/\/github.com\/user-attachments\/assets\/12345678-1234-4234-8234-1234567890ab"}' "$mint" "$tmp/real.png" --repo a/b
check "a URL nested in another object is not read" 7 "without an attachment URL" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{\"data\":{\"url\":\"$asset\"}}" "$mint" "$tmp/real.png" --repo a/b
check "malformed JSON is refused" 7 "without an attachment URL" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{\"url\":\"$asset\"" "$mint" "$tmp/real.png" --repo a/b
check_line "only the first top-level URL is printed" 0 "$asset" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{\"a\":\"$asset\",\"b\":\"https://github.com/user-attachments/assets/99999999-9999-4999-8999-999999999999\"}" "$mint" "$tmp/real.png" --repo a/b

# The strict reader refuses every body JSON.parse would refuse, not only the
# unbalanced one above: trailing text, a trailing comma, a bare key, a missing
# colon, a bad escape, and a raw control character in a string.
check "trailing text after the JSON is refused" 7 "without an attachment URL" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{\"url\":\"$asset\"} x" "$mint" "$tmp/real.png" --repo a/b
check "a trailing comma is refused" 7 "without an attachment URL" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{\"url\":\"$asset\",}" "$mint" "$tmp/real.png" --repo a/b
check "a bare key is refused" 7 "without an attachment URL" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{url:\"$asset\"}" "$mint" "$tmp/real.png" --repo a/b
check "a missing colon is refused" 7 "without an attachment URL" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{\"a\" \"b\":\"$asset\"}" "$mint" "$tmp/real.png" --repo a/b
check "a bad escape is refused" 7 "without an attachment URL" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{\"url\":\"\\q\"}" "$mint" "$tmp/real.png" --repo a/b
check "a raw control character in a string is refused" 7 "without an attachment URL" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY=$'{"url":"https://github.com/user-attachments/assets/12345678-1234-4234-8234-1234567890ab\tx"}' "$mint" "$tmp/real.png" --repo a/b

# A leading-zero timeout reads as decimal: 08 is eight seconds, not octal.
check "a leading-zero timeout reads as decimal" 0 "$asset" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{\"url\":\"$asset\"}" "$mint" "$tmp/real.png" --repo a/b --timeout 08

# A TMPDIR path that holds a space must still clean every temp file: the
# tracked paths live in an array, not one space-joined string, so each path
# stays one element and rm removes the real file.
space_dir="$tmp/with space"; mkdir -p "$space_dir"
space_out="$(env TMPDIR="$space_dir" PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{\"url\":\"$asset\"}" "$mint" "$tmp/real.png" --repo a/b 2>&1)"; space_rc=$?
if [ "$space_rc" = 0 ] && [ "$space_out" = "$asset" ] && [ -z "$(ls -A "$space_dir" 2>/dev/null)" ]; then
	pass=$((pass + 1)); printf 'ok   a TMPDIR with a space leaves no temp file\n'
else
	fail=$((fail + 1)); printf 'FAIL TMPDIR with a space (exit %s)\n     %s\n' "$space_rc" "$space_out"
fi

# A hidden .shot.png keeps its .png type; a dotfile named .png has none.
printf '\x89PNG\r\n\x1a\n' > "$tmp/.shot.png"
check "a hidden .shot.png keeps its .png type" 0 "$asset" -- env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{\"url\":\"$asset\"}" "$mint" "$tmp/.shot.png" --repo a/b
printf '\x89PNG\r\n\x1a\n' > "$tmp/.png"
check "a dotfile named .png has no extension" 9 "is not a PNG, JPEG, GIF or WebP" -- "$mint" "$tmp/.png" --repo a/b

# -q must be curl's first argument, so a .curlrc cannot record or forward the
# token or add -L.
check "curl gets -q first, before .curlrc can act" 0 "$asset" -- env PATH="$fake_path" GH_AUTH=1 CURL_REQUIRE_Q=1 CURL_STATUS=201 CURL_BODY="{\"url\":\"$asset\"}" "$mint" "$tmp/real.png" --repo a/b

# A signal at any step must leave no temp file and no child process. The fake
# curl hangs, records its pid, and waits; a signaller waits for that marker and
# then signals mint.sh. TMPDIR points at a private dir, so an empty dir after
# the signal means every temp file was removed. TERM and HUP are tested; a
# background shell ignores INT, so INT cannot be delivered this way, but the
# trap in mint.sh and token.sh is the same for all three.
for spec in "TERM 143" "HUP 129"; do
	sig="${spec% *}"; want="${spec#* }"
	tdir="$tmp/sig-$sig"; mkdir -p "$tdir"
	marker="$tmp/marker-$sig"; rm -f "$marker"
	env TMPDIR="$tdir" PATH="$signal_path" GH_AUTH=1 SIGNAL_MARKER="$marker" "$mint" "$tmp/real.png" --repo a/b &
	mintpid=$!
	( i=0; while [ ! -s "$marker" ] && [ "$i" -lt 200000 ]; do i=$((i + 1)); done; kill -"$sig" "$mintpid" 2>/dev/null ) &
	signer=$!
	wait "$mintpid" 2>/dev/null; got=$?
	wait "$signer" 2>/dev/null
	curlpid="$(cat "$marker" 2>/dev/null || true)"
	alive=0
	[ -n "$curlpid" ] && kill -0 "$curlpid" 2>/dev/null && alive=1
	if [ "$got" = "$want" ] && [ -z "$(ls -A "$tdir" 2>/dev/null)" ] && [ "$alive" -eq 0 ]; then
		pass=$((pass + 1)); printf 'ok   %s leaves no temp file or child\n' "$sig"
	else
		fail=$((fail + 1)); printf 'FAIL %s cleanup (exit %s, wanted %s)\n' "$sig" "$got" "$want"
	fi
done

# run_timed's watchdog is a subshell that inherits the EXIT trap. Under load, a
# TERM that lands before the watchdog arms its own trap runs the inherited trap
# and deletes the output file the caller is about to read back. Pin one CPU and
# run the fast path many times with two busy loops on that CPU; every run must
# print the asset. Without the BASH_SUBSHELL guard in cleanup, some runs read an
# empty id or token and fail. The loops are killed after the runs and self-limit
# as a backstop, and the fakes shadow gh-mint, so no run reaches a real broker.
if command -v taskset >/dev/null 2>&1; then
	race_cpu=0
	race_ok=1
	race_rc=0
	race_out=''
	race_b1=''; race_b2=''
	race_kill_loops() {
		[ -n "$race_b1" ] && kill "$race_b1" 2>/dev/null
		[ -n "$race_b2" ] && kill "$race_b2" 2>/dev/null
		wait "$race_b1" 2>/dev/null
		wait "$race_b2" 2>/dev/null
		race_b1=''; race_b2=''
	}
	taskset -c "$race_cpu" bash -c 'i=0; while [ "$i" -lt 5000000 ]; do :; i=$((i + 1)); done' &
	race_b1=$!
	taskset -c "$race_cpu" bash -c 'i=0; while [ "$i" -lt 5000000 ]; do :; i=$((i + 1)); done' &
	race_b2=$!
	race_i=0
	while [ "$race_i" -lt 20 ]; do
		race_out="$(env PATH="$fake_path" GH_AUTH=1 CURL_STATUS=201 CURL_BODY="{\"url\":\"$asset\"}" taskset -c "$race_cpu" "$mint" "$tmp/real.png" --repo a/b 2>&1)"
		race_rc=$?
		if [ "$race_rc" -ne 0 ] || [ "$race_out" != "$asset" ]; then
			race_ok=0
			break
		fi
		race_i=$((race_i + 1))
	done
	race_kill_loops
	if [ "$race_ok" -eq 1 ]; then
		pass=$((pass + 1)); printf 'ok   run_timed keeps its output under load\n'
	else
		fail=$((fail + 1)); printf 'FAIL run_timed lost its output under load (exit %s)\n     %s\n' "$race_rc" "$race_out"
	fi
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

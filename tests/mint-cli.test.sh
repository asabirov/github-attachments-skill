#!/usr/bin/env bash
# What mint.sh refuses, and how fast.
#
# Every case here is refused before anything is uploaded. That is the point: a bad --repo
# or a 12 MB file should cost nothing, and the failure that actually hurt in testing was
# an over-size image that uploaded for a minute and then timed out, because GitHub rejects
# on size after the transfer rather than before it.

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

# 11 MB, over GitHub's 10 MB ceiling, and refused without a byte going out.
mkfile_size=$((11 * 1024 * 1024))
dd if=/dev/zero of="$tmp/huge.png" bs=1024 count=$((mkfile_size / 1024)) 2>/dev/null
check "oversize image is refused early"  2 "limit is 10 MB"      -- "$mint" "$tmp/huge.png" --repo a/b

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

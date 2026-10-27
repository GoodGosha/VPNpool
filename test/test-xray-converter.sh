#!/bin/sh
# Run with jq and base64 available; ucode parser integration is checked when present.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONVERTER="$ROOT/package/vpnpool/files/usr/libexec/vpnpool/xray-convert.sh"
PARSER="$ROOT/package/vpnpool/files/usr/libexec/vpnpool/parser.uc"
FIXTURE="$ROOT/test/fixtures/cdngenix.xray.json"
EMPTY_FIXTURE="$ROOT/test/fixtures/xray-no-nodes.json"

encoded=$(sh "$CONVERTER" "$FIXTURE")
[ -n "$encoded" ] || { echo "FAIL: converter returned empty output" >&2; exit 1; }
decoded=$(printf '%s' "$encoded" | base64 -d)
count=$(printf '%s\n' "$decoded" | wc -l | tr -d ' ')
[ "$count" = 6 ] || { echo "FAIL: expected 6 proxy links, got $count" >&2; exit 1; }

for scheme in 'vless://' 'vmess://' 'trojan://' 'ss://'; do
	printf '%s\n' "$decoded" | grep -Fq "$scheme" || {
		echo "FAIL: missing $scheme link" >&2; exit 1;
	}
done
printf '%s\n' "$decoded" | grep -Fq '@[2001:db8::1]:443' || {
	echo "FAIL: IPv6 endpoint was not bracketed" >&2; exit 1;
}
if printf '%s\n' "$decoded" | grep -Eq 'freedom|blackhole'; then
	echo "FAIL: non-proxy outbound was converted" >&2; exit 1
fi
empty=$(sh "$CONVERTER" "$EMPTY_FIXTURE")
[ -z "$empty" ] || { echo "FAIL: converter emitted links for an empty Xray profile" >&2; exit 1; }

if command -v ucode >/dev/null 2>&1; then
	parsed=$(printf '%s\n' "$decoded" | ucode "$PARSER")
	printf '%s' "$parsed" | jq -e 'length == 6' >/dev/null || {
		echo "FAIL: parser.uc did not accept all generated links" >&2; exit 1;
	}
fi

echo "OK: converted $count proxy links to Base64"

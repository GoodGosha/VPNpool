#!/bin/sh
# vpnpool: fetch every source trying MULTIPLE client User-Agents, detect the
# format of each response (base64 / sing-box JSON / plain link list), parse it,
# and keep the response that yields the MOST nodes. This makes the fetcher
# robust to subscription panels that serve different formats to different
# clients (and to the provider changing over time).
#
# Output: one decoded file per source in $SB_DATA/sources/NNN.raw, cached to
#         $CONF_DIR/sources_cache for offline fallback.
. /usr/libexec/vpnpool/lib.sh

mkdir -p "$SB_DATA"
SRCDIR="$SB_DATA/sources"
CACHEDIR="$CONF_DIR/sources_cache"

# Client User-Agents to probe (space separated, no spaces inside a UA).
UAS=$(uci -q get vpnpool.main.probe_ua)
[ -n "$UAS" ] || UAS="v2rayNG/1.9.5 v2rayN/6.45 Happ/1.0 sing-box/1.12 clash-meta/1.18 Streisand Hiddify/2.0 Shadowrocket/2.2 Mozilla/5.0"

# Build one stable header set for every configured source. UCI lists preserve spaces
# inside values; do not read custom_headers with `uci get` (it joins list items).
HEADER_FILE="$SB_DATA/request-headers"
HEADER_TMP="$SB_DATA/request-headers.tmp"
: > "$HEADER_FILE"
add_header() {   # $1 = one UCI list entry or preset header
	local line name key
	line=$(printf '%s' "$1" | tr -d '\r')
	if printf '%s' "$line" | LC_ALL=C grep -q '[[:cntrl:]]'; then
		log "fetch: ignoring header containing a control character"; return 0
	fi
	case "$line" in *:*) ;; *) log "fetch: ignoring malformed custom header"; return 0 ;; esac
	name=$(printf '%s' "${line%%:*}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	[ -n "$name" ] || { log "fetch: ignoring header with an empty name"; return 0; }
	key=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
	# Header names are case-insensitive. Replacing an existing line implements the
	# documented custom-over-preset precedence without emitting duplicate headers.
	awk -F: -v k="$key" 'tolower($1) != k' "$HEADER_FILE" > "$HEADER_TMP" 2>/dev/null
	mv "$HEADER_TMP" "$HEADER_FILE"
	printf '%s\n' "$name:${line#*:}" >> "$HEADER_FILE"
}

HAPP_ENABLED=$(uci -q get vpnpool.main.happ_preset_enabled)
if [ "$HAPP_ENABLED" = "1" ]; then
	HAPP_HWID=$(uci -q get vpnpool.main.happ_hwid); [ -n "$HAPP_HWID" ] || HAPP_HWID=d557890a98d45a4f0fbecd88c34e3d79
	HAPP_MODEL=$(uci -q get vpnpool.main.happ_device_model); [ -n "$HAPP_MODEL" ] || HAPP_MODEL='Pixel 8 Pro'
	HAPP_OS=$(uci -q get vpnpool.main.happ_device_os); [ -n "$HAPP_OS" ] || HAPP_OS=Android
	HAPP_LOCALE=$(uci -q get vpnpool.main.happ_device_locale); [ -n "$HAPP_LOCALE" ] || HAPP_LOCALE=ru
	HAPP_VER_OS=$(uci -q get vpnpool.main.happ_ver_os); [ -n "$HAPP_VER_OS" ] || HAPP_VER_OS=15
	add_header 'User-Agent: Happ/3.13.0'
	add_header "X-Hwid: $HAPP_HWID"
	add_header "X-Device-Os: $HAPP_OS"
	add_header "X-Device-Locale: $HAPP_LOCALE"
	add_header "X-Device-Model: $HAPP_MODEL"
	add_header "X-Ver-Os: $HAPP_VER_OS"
fi

. /lib/functions.sh 2>/dev/null
collect_custom_header() { add_header "$1"; }
config_load vpnpool 2>/dev/null
config_list_foreach main custom_headers collect_custom_header 2>/dev/null
if [ -s "$HEADER_FILE" ]; then
	# curl otherwise injects its own curl/X.Y.Z User-Agent. Use the Happ-compatible
	# default for custom-header requests unless the user supplied an explicit UA.
	if ! grep -qi '^User-Agent:' "$HEADER_FILE"; then add_header 'User-Agent: Happ/3.13.0'; fi
	USE_CONFIG_HEADERS=1
else
	USE_CONFIG_HEADERS=0
	log "fetch: no configured headers; probing User-Agents"
fi

normalize() {   # $1 = raw body file -> decoded text on stdout
	c=$(head -c 1 "$1" 2>/dev/null)
	case "$c" in
		'{'|'[') cat "$1" ;;                                   # JSON
		*)
			if head -c 8 "$1" 2>/dev/null | grep -q '://'; then
				cat "$1"                                       # plain link list
			else
				# base64 blob: if it isn't valid base64, base64 -d exits early and
				# tr would SIGPIPE — silence tr's stderr too, then fall back to raw.
				tr -d '\r\n' < "$1" 2>/dev/null | base64 -d 2>/dev/null || cat "$1"
			fi ;;
	esac
}

fetch_best() {   # $1=url $2=primary(0/1) $3=outfile
	url="$1"; primary="$2"; outfile="$3"
	best=-1; bestua=""
	try_user_agent() {  # $1=UA; configured headers intentionally omit -A
		local ua="$1" h
		set -- -sSL --connect-timeout 5 -m 12
		if [ "$USE_CONFIG_HEADERS" = "1" ]; then
			while IFS= read -r h; do [ -n "$h" ] && set -- "$@" -H "$h"; done < "$HEADER_FILE"
		else
			set -- "$@" -A "$ua"
		fi
		set -- "$@" -D "$SB_DATA/h.tmp" -o "$SB_DATA/b.tmp" -w '%{http_code}' "$url"
		code=$(curl "$@" 2>/dev/null); rc=$?
		if [ "$rc" -ne 0 ]; then
			log "fetch: request failed (HTTP ${code:-000}, UA: ${ua:-configured headers})"
			return 1
		fi
		case "$code" in
			2??) ;;
			*)
				if [ "$USE_CONFIG_HEADERS" = "1" ]; then
					msg=$(head -c 200 "$SB_DATA/b.tmp" 2>/dev/null | tr '\r\n' ' ' | tr -cd '[:print:] ')
					log "fetch: HTTP $code with configured headers; response: $msg"
				else
					log "fetch: HTTP $code (UA: $ua)"
				fi
				return 1 ;;
		esac
		sz=$(wc -c < "$SB_DATA/b.tmp" 2>/dev/null); [ "${sz:-0}" -lt 20 ] || return 1
		normalize "$SB_DATA/b.tmp" > "$SB_DATA/n.tmp"
		cnt=$(ucode /usr/libexec/vpnpool/parser.uc "$SB_DATA/n.tmp" 2>/dev/null | jq 'length' 2>/dev/null)
		[ -n "$cnt" ] || cnt=0
		if [ "$cnt" -gt "$best" ]; then
			best="$cnt"; bestua="${ua:-configured headers}"; cp "$SB_DATA/n.tmp" "$outfile"
			if [ "$primary" = "1" ]; then
				UINFO=$(grep -i '^subscription-userinfo:' "$SB_DATA/h.tmp" 2>/dev/null | head -1); EXP=$(echo "$UINFO" | grep -o 'expire=[0-9]*' | head -1 | cut -d= -f2)
					UP=$(echo "$UINFO" | grep -o 'upload=[0-9]*' | head -1 | cut -d= -f2); DN=$(echo "$UINFO" | grep -o 'download=[0-9]*' | head -1 | cut -d= -f2); TOT=$(echo "$UINFO" | grep -o 'total=[0-9]*' | head -1 | cut -d= -f2)
					[ -n "$TOT" ] && [ "$TOT" -gt 0 ] 2>/dev/null && echo "${UP:-0} ${DN:-0} ${TOT}" > "$CONF_DIR/sub.usage"
				[ -n "$EXP" ] && echo "$EXP" > "$CONF_DIR/sub.expire"
			fi
		fi
		[ "$cnt" -ge 1 ]
	}
	if [ "$USE_CONFIG_HEADERS" = "1" ]; then
		try_user_agent ""
	else
		# Preserve legacy multi-UA behavior unless a preset or custom header set is active.
		for ua in $UAS; do
			try_user_agent "$ua" && break
		done
	fi
	if [ "$best" -ge 1 ]; then
		log "fetch: $url -> $best nodes (best UA: $bestua)"
		return 0
	fi
	log "fetch: $url -> no usable nodes from any client"
	return 1
}

rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"
n=0; ok=0
if [ -n "$SUB_URL" ]; then
	fetch_best "$SUB_URL" 1 "$SRCDIR/$(printf '%03d' "$n").raw" && ok=1
	n=$((n + 1))
fi

# Extra FULL subscriptions (uci list extra_sub): bulk-merged into the pool like the
# primary, each into its own NNN.raw (build.sh merges every *.raw). Quota/expiry are
# only taken from the PRIMARY subscription (primary=0 here). vless:// links have no
# spaces, so a plain `uci get` list read is safe.
for esub in $(uci -q get vpnpool.main.extra_sub); do
	[ -n "$esub" ] || continue
	fetch_best "$esub" 0 "$SRCDIR/$(printf '%03d' "$n").raw" && ok=1
	n=$((n + 1))
done
# NOTE: extra `source` URLs are NOT bulk-merged anymore — a public list can carry
# hundreds/thousands of nodes and flood the pool. They are now "probe-only": the
# UI fetches a source, the user picks specific nodes, and those are stored as
# `imported_node` links (merged in build.sh). See probe.sh / add_imported.

if [ "$ok" = "1" ]; then
	rm -rf "$CACHEDIR"; cp -a "$SRCDIR" "$CACHEDIR" 2>/dev/null
	exit 0
fi

log "fetch: all sources failed, trying cache"
if [ -d "$CACHEDIR" ]; then
	rm -rf "$SRCDIR"; cp -a "$CACHEDIR" "$SRCDIR"
	# Warn (log + Telegram) when serving a STALE cache: nodes may be long dead and the
	# subscription likely expired, but we keep the tunnel up on the last-known set. Without
	# this the user has no signal that they're running on a frozen, possibly-dead snapshot.
	age_days=0
	mt=$(date -r "$CACHEDIR" +%s 2>/dev/null); now=$(date +%s)
	[ -n "$mt" ] && age_days=$(( (now - mt) / 86400 ))
	if [ "$age_days" -ge 3 ]; then
		log "fetch: serving CACHED sources (~${age_days}d old) — subscription unreachable, nodes may be dead"
		tg_notify "⚠️ vpnpool: подписка недоступна, работаю на кэше (~${age_days} дн.) — узлы могут быть мертвы"
	fi
	exit 0
fi
exit 1

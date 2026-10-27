#!/bin/sh
#!/bin/sh
# Convert Xray share JSON (a profile or an array of profiles) to a standard
# Base64-encoded link list understood by parser.uc. Only uses jq, already required
# by the vpnpool package; jq's @base64 avoids platform-specific `base64 -w` flags.
set -eu

INPUT=${1:--}
jq -r '
	def first:
		if type == "array" then .[0] // "" else . // "" end;
	def uri_host:
		tostring as $h
		| if ($h | startswith("[")) and ($h | endswith("]")) then $h
		  elif ($h | contains(":")) then "[" + $h + "]"
		  else $h end;
	def pair($key; $value):
		if $value == null or (($value | tostring) == "") then null
		else [$key, ($value | tostring)] end;
	def query($pairs):
		[$pairs[] | select(. != null) | .[0] + "=" + (.[1] | @uri)] | join("&");
	def node_label:
		if (.tag // "") != "" then .tag
		elif (.profile_name // "") != "" then .profile_name
		else .protocol + "-" + .address + ":" + (.port | tostring) end;
	def portstr: (.port | tostring);
	def link:
		. as $n
		| ($n.address | uri_host) as $host
		| ($n.port | tostring) as $port
		| ($n | node_label | @uri) as $name
		| if $n.protocol == "vless" then
			[
				pair("encryption"; "none"), pair("security"; $n.security),
				pair("type"; $n.network), pair("flow"; $n.flow),
				pair("sni"; $n.sni), pair("fp"; $n.fingerprint),
				pair("pbk"; $n.public_key), pair("sid"; $n.short_id),
				pair("path"; $n.path), pair("host"; $n.host),
				pair("serviceName"; $n.service_name), pair("authority"; $n.authority),
				pair("alpn"; $n.alpn)
			] | query(.) as $q
			| "vless://" + ($n.user_id | tostring | @uri) + "@" + $host + ":" + $port
			  + (if $q == "" then "" else "?" + $q end) + "#" + $name
		elif $n.protocol == "vmess" then
			{
				v: "2", ps: ($n | node_label), add: $n.address, port: $port,
				id: ($n.user_id // ""), aid: (($n.alter_id // 0) | tostring),
				scy: ($n.vmess_security // "auto"), net: ($n.network // "tcp"),
				type: ($n.vmess_type // "none"), host: ($n.host // ""),
				path: (if $n.network == "grpc" then ($n.service_name // "") else ($n.path // "") end),
				tls: (if $n.security == "tls" or $n.security == "reality" then "tls" else "" end),
				sni: ($n.sni // ""), alpn: ($n.alpn // ""), fp: ($n.fingerprint // "")
			} | tojson | @base64 | "vmess://" + .
		elif $n.protocol == "trojan" then
			[
				pair("security"; $n.security), pair("type"; $n.network),
				pair("sni"; $n.sni), pair("fp"; $n.fingerprint),
				pair("path"; $n.path), pair("host"; $n.host),
				pair("serviceName"; $n.service_name), pair("alpn"; $n.alpn)
			] | query(.) as $q
			| "trojan://" + ($n.password | tostring | @uri) + "@" + $host + ":" + $port
			  + (if $q == "" then "" else "?" + $q end) + "#" + $name
		elif $n.protocol == "shadowsocks" then
			"ss://" + ((($n.method // "") + ":" + ($n.password // "")) | @base64)
			+ "@" + $host + ":" + $port + "#" + $name
		else empty end;

	[
		(if type == "array" then .[] else . end) as $profile
		| ($profile.outbounds // [])[]? as $outbound
		| ($outbound.protocol // "") as $protocol
		| select($protocol == "vless" or $protocol == "vmess" or $protocol == "trojan" or $protocol == "shadowsocks")
		| ($outbound.settings // {}) as $settings
		| ($outbound.streamSettings // {}) as $stream
		| ($stream.security // "none") as $security
		| (if $security == "reality" then ($stream.realitySettings // {})
		   elif $security == "tls" then ($stream.tlsSettings // {}) else {} end) as $tls
		| ([$settings.vnext[]? | . as $server | ($server.users // [])[]? |
			{server: $server, user: .}] 
		   + [$settings.servers[]? | {server: ., user: .}])[] as $entry
		| ($entry.server.address // "") as $address
		| ($entry.server.port // 0) as $port
		| ($entry.user // {}) as $user
		| {
			protocol: $protocol,
			tag: ($outbound.tag // $outbound.remarks // ""),
			profile_name: ($profile.remarks // $profile.remark // $profile.name // ""),
			address: $address, port: $port,
			user_id: ($user.id // ""), flow: ($user.flow // ""),
			password: ($entry.server.password // ""),
			method: ($entry.server.method // $entry.server.cipher // ""),
			alter_id: ($user.alterId // 0),
			vmess_security: ($user.security // $entry.server.security // "auto"),
			network: ($stream.network // "tcp"), security: $security,
			fingerprint: ($tls.fingerprint // ""),
			sni: ($tls.serverName // ($tls.serverNames | first) // ""),
			public_key: ($tls.publicKey // ($tls.publicKeys | first) // ""),
			short_id: ($tls.shortId // ($tls.shortIds | first) // ""),
			alpn: (if ($tls.alpn | type) == "array" then ($tls.alpn | join(",")) else ($tls.alpn // "") end),
			host: ([$stream.wsSettings.headers.Host, $stream.wsSettings.headers.host,
				$stream.wsSettings.host, $stream.httpSettings.host, $stream.httpSettings.headers.Host]
				| map(select(. != null)) | first | first),
			path: ($stream.wsSettings.path // $stream.httpSettings.path // ""),
			service_name: ($stream.grpcSettings.serviceName // ""),
			authority: ($stream.grpcSettings.authority // ""),
			vmess_type: ($stream.tcpSettings.header.type // $stream.kcpSettings.header.type // "none")
		}
		| select(.address != "" and (.port | tonumber? // 0) > 0)
		| select(
			if .protocol == "vless" or .protocol == "vmess" then .user_id != ""
			elif .protocol == "trojan" then .password != ""
			elif .protocol == "shadowsocks" then .method != "" and .password != ""
			else false end
		)
		| select(.protocol != "vless" or .security != "reality" or .public_key != "")
	]
	| map(link)
	| map(select(type == "string" and length > 0))
	| join("\n")
	| @base64
' "$INPUT"

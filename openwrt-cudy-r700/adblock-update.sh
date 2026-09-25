#!/bin/sh
# =============================================================================
#  adblock-update.sh - load a dnsmasq ad-block list from the LAN, check that
#  blocking really works, and send a mail when it doesn't
#
#  Downloads http://dnsmasq.lan/adblock.conf (dnsmasq format: address=/.../),
#  checks it with "dnsmasq --test" and puts it into dnsmasq's conf-dir. In
#  OpenWrt 25.12 that is per instance, /tmp/dnsmasq.<instance>.d (not the old
#  /tmp/dnsmasq.d), and dnsmasq runs jailed, so the file must be inside it.
#  dnsmasq is restarted only when the list changed; if it doesn't come back
#  up, the list is taken out again so DNS keeps working.
#
#  The check: dnsmasq answers, the list is loaded, the last update worked,
#  normal names still resolve, and domains from the list that 1.1.1.1 still
#  resolves come back blocked from the router. A problem is mailed once (with
#  /opt/scripts/sendmail "subject" "body"), and again when it is fixed.
#
#  sh /tmp/adblock-update.sh install   install to /usr/sbin/adblock-update:
#                                      update daily + at boot, check hourly,
#                                      keep it across sysupgrades
#  adblock-update                      update now, then check
#  adblock-update check                check now
#  adblock-update mailtest             send a test mail
#  adblock-update remove               uninstall and unload the list
# =============================================================================

URL="http://dnsmasq.lan/adblock.conf"   # where the list comes from
NAME="adblock.conf"                     # file name inside dnsmasq's conf-dir
UPDATE_CRON="30 4 * * *"                # update: daily at 04:30
CHECK_CRON="15 * * * *"                 # check: every hour at :15
MAILER=/opt/scripts/sendmail            # called as: sendmail "subject" "body"
UPSTREAM=1.1.1.1                        # outside resolver to compare with
NORMAL_NAME=openwrt.org                 # must keep resolving
SAMPLES=3                               # live list domains to test

BIN=/usr/sbin/adblock-update
TAG=adblock
STATE=/tmp/adblock.alert                # problems already mailed
UPDATE_ERR=/tmp/adblock.update-error    # why the last update failed
RULES='^[[:space:]]*(address|server|local)=/'
PATH=/usr/sbin:/usr/bin:/sbin:/bin

log() { logger -t "$TAG" "$*"; [ -t 2 ] && echo "$*" >&2; }
host_name() { cat /proc/sys/kernel/hostname 2>/dev/null; }
now() { date '+%Y-%m-%d %H:%M'; }

# conf-dir of every running dnsmasq instance (from its generated config);
# if dnsmasq isn't running, work it out from /etc/config/dhcp
conf_dirs() {
	local f d list=""
	for f in /var/etc/dnsmasq.conf.*; do
		[ -f "$f" ] || continue
		d="$(sed -n 's/^conf-dir=\([^,]*\).*/\1/p' "$f" | head -n 1)"
		[ -n "$d" ] && list="$list $d"
	done
	if [ -z "$list" ]; then
		for f in $(uci -X show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p'); do
			d="$(uci -q get "dhcp.$f.confdir")"
			d="${d%%,*}"
			list="$list ${d:-/tmp/dnsmasq.$f.d}"
		done
	fi
	[ -n "$list" ] && printf '%s\n' $list | sort -u
}

fetch() {   # <url> <file>
	if command -v curl >/dev/null 2>&1; then
		curl -fsS --connect-timeout 10 --max-time 120 -o "$2" "$1"
	else
		uclient-fetch -q -T 120 -O "$2" "$1"
	fi
}

# addresses in the answer for <name> from <server> (nothing = NXDOMAIN etc.)
lookup() {
	nslookup "$1" "$2" </dev/null 2>/dev/null | awk '
		/^Name:/ { n = 1; next }
		n && /^Address/ {
			for (i = 2; i <= NF; i++)
				if ($i ~ /^[0-9a-fA-F:.]+$/ && $i ~ /[.:]/ && $i !~ /^[0-9]+:$/) print $i
		}'
}

# dnsmasq on 127.0.0.1 replies at all (any answer, even NXDOMAIN)
dns_answers() {
	nslookup localhost 127.0.0.1 </dev/null 2>&1 | grep -qE '^Name:|NXDOMAIN'
}

# true if all <addresses> are "blocked" answers: 0.0.0.0, ::, 127.0.0.1,
# ::1 or the address the rule itself gives
only_null() {
	local a
	for a in $1; do
		case "$a" in
			0.0.0.0|::|127.0.0.1|::1) ;;
			*) [ -n "$2" ] && [ "$a" = "$2" ] || return 1 ;;
		esac
	done
	return 0
}

dns_restart() {
	local i=0
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	while [ "$i" -lt 30 ]; do       # a big list takes a while to load
		sleep 1
		dns_answers && return 0
		i=$((i + 1))
	done
	return 1
}

fail() { log "$*"; echo "$*" >"$UPDATE_ERR"; }

update() {
	local tmp="/tmp/.$TAG.$$" dirs d n changed=0
	if ! fetch "$URL" "$tmp"; then
		fail "download of $URL failed"
		rm -f "$tmp"
		return 1
	fi
	n=$(grep -cE "$RULES" "$tmp")
	if [ "$n" -eq 0 ]; then
		fail "$URL has no address=/, server=/ or local=/ lines"
		rm -f "$tmp"
		return 1
	fi
	if ! dnsmasq --test --conf-file="$tmp" >/dev/null 2>&1; then
		fail "$URL fails dnsmasq's syntax check"
		rm -f "$tmp"
		return 1
	fi
	dirs="$(conf_dirs)"
	if [ -z "$dirs" ]; then
		fail "no dnsmasq instance found in /etc/config/dhcp"
		rm -f "$tmp"
		return 1
	fi
	for d in $dirs; do
		mkdir -p "$d"
		cmp -s "$tmp" "$d/$NAME" && continue
		cp "$tmp" "$d/.$NAME.new" && chmod 644 "$d/.$NAME.new" &&
			mv -f "$d/.$NAME.new" "$d/$NAME" && changed=1
	done
	rm -f "$tmp"
	if [ "$changed" = 0 ]; then
		log "list unchanged ($n rules)"
		rm -f "$UPDATE_ERR"
		return 0
	fi
	if dns_restart; then
		log "list loaded: $n rules, dnsmasq restarted"
		rm -f "$UPDATE_ERR"
		return 0
	fi
	fail "dnsmasq did not come back with the new list - list removed"
	for d in $dirs; do rm -f "$d/$NAME"; done
	dns_restart
	return 1
}

boot() {    # the LAN server may come up later than the router: retry ~10 min
	local i=0
	while [ "$i" -lt 20 ]; do
		update && return 0
		i=$((i + 1))
		sleep 30
	done
	return 1
}

# "domain target" pairs spread over the list, ~30 of them (target = the
# address the rule answers with, empty for NXDOMAIN rules)
candidates() {
	awk -F/ -v total="$(grep -cE "$RULES" "$1")" '
		BEGIN { step = int(total / 30); if (step < 1) step = 1 }
		/^[[:space:]]*(address|server|local)=\// && $2 != "" && $2 != "#" &&
		($1 !~ /server=/ || $NF == "") { if (i++ % step == 0) print $2, $NF }' "$1"
}

# prints "key|message" for each problem (no problems = everything works),
# plus one "note|..." line saying what was verified
verify() {
	local dirs d f="" up loc dom target tested=0
	if ! dns_answers; then
		echo "dnsmasq|dnsmasq does not answer DNS queries on 127.0.0.1"
		return
	fi
	dirs="$(conf_dirs)"
	for d in $dirs; do
		if [ -s "$d/$NAME" ]; then f="$d/$NAME"
		else echo "missing|the block list is not loaded ($d/$NAME is missing)"; fi
	done
	[ -f "$UPDATE_ERR" ] && echo "update|the last list update failed: $(cat "$UPDATE_ERR")"

	# the rest compares with an outside resolver, so it needs the internet
	if [ -z "$(lookup "$NORMAL_NAME" "$UPSTREAM")" ]; then
		echo "note|blocking not tested, no answer from $UPSTREAM"
		return
	fi
	loc="$(lookup "$NORMAL_NAME" 127.0.0.1)"
	if [ -z "$loc" ] || only_null "$loc"; then
		echo "resolve|normal names don't resolve through the router ($NORMAL_NAME) - DNS is broken or the list blocks too much"
	fi
	[ -n "$f" ] || return
	candidates "$f" >"/tmp/.$TAG.cand"
	while read -r dom target; do
		[ "$tested" -ge "$SAMPLES" ] && break
		up="$(lookup "$dom" "$UPSTREAM")"
		[ -n "$up" ] && ! only_null "$up" || continue   # dead domain, proves nothing
		tested=$((tested + 1))
		loc="$(lookup "$dom" 127.0.0.1)"
		[ -z "$loc" ] || only_null "$loc" "$target" ||
			echo "blocking|$dom is not blocked: the router answers $(echo $loc)"
	done <"/tmp/.$TAG.cand"
	rm -f "/tmp/.$TAG.cand"
	if [ "$tested" -gt 0 ]; then
		echo "note|ads are blocked ($tested live domains from the list tested)"
	else
		echo "note|blocking not tested, no live domain found in the list"
	fi
}

notify() {  # <subject> <body>
	local rc
	if [ ! -f "$MAILER" ]; then
		log "cannot send mail: $MAILER not found"
		return 1
	fi
	if [ -x "$MAILER" ]; then "$MAILER" "$1" "$2"; else sh "$MAILER" "$1" "$2"; fi >/dev/null 2>&1
	rc=$?
	if [ "$rc" -eq 0 ]; then log "mail sent: $1"; else log "sending mail failed ($MAILER exit $rc)"; fi
	return "$rc"
}

report() {  # mail body for <problems>
	local d f
	echo "Adblock check on $(host_name) failed at $(now):"
	echo
	echo "$1" | cut -d'|' -f2- | sed 's/^/- /'
	echo
	for d in $(conf_dirs); do
		f="$d/$NAME"
		[ -f "$f" ] && echo "List: $f, $(grep -cE "$RULES" "$f") rules, loaded $(date -r "$f" '+%Y-%m-%d %H:%M')"
	done
	echo "Source: $URL"
	echo
	echo "Recent log:"
	logread -e "$TAG" 2>/dev/null | tail -n 8
}

check() {   # verify; mail when the set of problems changes
	local result problems note keys
	result="$(verify)"
	problems="$(echo "$result" | grep -v '^note|')"
	note="$(echo "$result" | sed -n 's/^note|//p' | head -n 1)"
	if [ -z "$problems" ]; then
		log "check OK - ${note:-ads are blocked}"
		if [ -f "$STATE" ]; then
			notify "[$(host_name)] adblock works again" \
				"Adblock on $(host_name) is working again ($(now))." && rm -f "$STATE"
		fi
		return 0
	fi
	echo "$problems" | while IFS='|' read -r k msg; do log "PROBLEM: $msg"; done
	keys="$(echo "$problems" | cut -d'|' -f1 | sort -u | tr '\n' ' ')"
	if [ "$keys" != "$(cat "$STATE" 2>/dev/null)" ]; then
		# remember only if the mail went out, so a failed mail is retried
		notify "[$(host_name)] adblock is not working" "$(report "$problems")" &&
			echo "$keys" >"$STATE"
	fi
	return 1
}

lock() {    # one run at a time (cron and boot could overlap)
	LOCK="/tmp/$TAG.lock"
	if ! mkdir "$LOCK" 2>/dev/null; then
		kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null && exit 0
		rm -rf "$LOCK"
		mkdir "$LOCK" || exit 1
	fi
	echo $$ >"$LOCK/pid"
	trap 'rm -rf "$LOCK"' EXIT
	trap 'exit 1' INT TERM
}

# remove lines matching <pattern> from <file>, keeping the file itself
drop_lines() {
	[ -f "$2" ] || return 0
	grep -v "$1" "$2" >"/tmp/.$TAG.edit"
	cat "/tmp/.$TAG.edit" >"$2"
	rm -f "/tmp/.$TAG.edit"
}

install() {
	[ -w /etc/config/dhcp ] || { echo "Run this as root on the router."; exit 1; }
	command -v dnsmasq >/dev/null 2>&1 || { echo "dnsmasq is not installed."; exit 1; }
	if [ "$0" != "$BIN" ]; then
		[ -f "$0" ] || { echo "Run it as: sh /path/to/adblock-update.sh install"; exit 1; }
		cp "$0" "$BIN" && chmod 755 "$BIN" || exit 1
	fi

	# daily update, hourly check
	touch /etc/crontabs/root
	drop_lines "$BIN" /etc/crontabs/root
	echo "$UPDATE_CRON $BIN" >>/etc/crontabs/root
	echo "$CHECK_CRON $BIN check" >>/etc/crontabs/root
	/etc/init.d/cron enable
	/etc/init.d/cron restart

	# at boot (in the background; rc.local runs after all services)
	if ! grep -q "$BIN" /etc/rc.local 2>/dev/null; then
		awk -v l="$BIN --boot >/dev/null 2>&1 &" \
			'/^exit 0/ && !d { print l; d = 1 } { print } END { if (!d) print l }' \
			/etc/rc.local >"/tmp/.$TAG.edit"
		cat "/tmp/.$TAG.edit" >/etc/rc.local
		rm -f "/tmp/.$TAG.edit"
	fi

	# sysupgrade keeps /etc/config, crontabs and rc.local, but not this
	# script unless it is listed here (that's how the old one got lost)
	grep -qx "$BIN" /etc/sysupgrade.conf 2>/dev/null || echo "$BIN" >>/etc/sysupgrade.conf

	echo "Installed $BIN: update at '$UPDATE_CRON' and boot, check at '$CHECK_CRON'."
	[ -f "$MAILER" ] || echo "Note: $MAILER not found - problems will only be logged."
	echo "Loading the list and checking it..."
	lock
	update
	check
}

remove() {
	local d
	for d in $(conf_dirs); do rm -f "$d/$NAME"; done
	dns_restart
	drop_lines "$BIN" /etc/crontabs/root
	/etc/init.d/cron restart
	drop_lines "$BIN" /etc/rc.local
	drop_lines "^$BIN\$" /etc/sysupgrade.conf
	rm -f "$BIN" "$STATE" "$UPDATE_ERR"
	echo "Removed: list unloaded, no more updates or checks."
}

case "$1" in
	install) install ;;
	remove) remove ;;
	check) lock; check ;;
	mailtest)
		notify "[$(host_name)] adblock test mail" \
			"Test mail from $BIN on $(host_name) at $(now)." ;;
	--boot) lock; boot; check ;;
	""|update) lock; update; check ;;
	*) echo "Usage: $0 [update|check|mailtest|install|remove]"; exit 1 ;;
esac

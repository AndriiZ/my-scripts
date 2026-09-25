#!/bin/sh
# =============================================================================
#  dante-via-backup.sh - send dante-server (sockd) traffic out the backup ISP
#
#  "external: lan2" in /etc/sockd.conf makes dante use wan2's address as the
#  source of its outgoing connections, but mwan3 still routes them by the
#  failover policy (main ISP), where NAT swaps the source address. This adds
#  an mwan3 rule "traffic the router sends from wan2's own address leaves via
#  wan2", plus a hotplug hook that follows wan2's address when it changes.
#
#  Run it on the router after mwan3-setup.sh:
#      sh /tmp/dante-via-backup.sh
#  Undo:
#      sh /tmp/dante-via-backup.sh --remove
# =============================================================================

WANB_IF="wan2"            # backup ISP interface (as in mwan3-setup.sh)
RULE="backup_src"         # mwan3 rule name (max 15 characters)
POLICY="backup_only"      # backup down -> dante connections fail at once
                          # instead of quietly going out the main ISP

UPDATER=/usr/sbin/mwan3-backup-src
HOOK=/etc/hotplug.d/iface/99-mwan3-backup-src

info() { echo "[*] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[x] $*"; exit 1; }

[ -w /etc/config/network ] || die "Run this script as root on the router."
[ -x /usr/sbin/mwan3 ] || die "mwan3 is not installed - run mwan3-setup.sh first."

if [ "$1" = --remove ]; then
	rm -f "$HOOK" "$UPDATER"
	if [ -f /etc/sysupgrade.conf ]; then
		grep -vx -e "$UPDATER" -e "$HOOK" /etc/sysupgrade.conf >/tmp/.sysupgrade.conf.$$
		cat /tmp/.sysupgrade.conf.$$ >/etc/sysupgrade.conf
		rm -f /tmp/.sysupgrade.conf.$$
	fi
	uci -q delete "mwan3.$RULE" && uci commit mwan3
	/etc/init.d/mwan3 restart
	info "Removed - dante follows the normal mwan3 policy again."
	exit 0
fi

[ "$(uci -q get "mwan3.$WANB_IF")" = interface ] ||
	die "'$WANB_IF' is not configured in mwan3."
[ "$(uci -q get "mwan3.$POLICY")" = policy ] ||
	die "mwan3 policy '$POLICY' does not exist."

. /lib/functions/network.sh
network_get_device DEV "$WANB_IF"
network_get_ipaddr IP "$WANB_IF"
[ -n "$IP" ] || die "'$WANB_IF' has no IPv4 address - is the backup ISP connected?"

if [ -f /etc/sockd.conf ] &&
   ! grep -Eq "^[[:space:]]*external:[[:space:]]*($DEV|$IP)([[:space:]]|\$)" /etc/sockd.conf; then
	warn "/etc/sockd.conf has no 'external: $DEV' - dante won't send from the backup's address."
fi

# --- the updater: keeps the rule's source address equal to wan2's address ---
{
	echo '#!/bin/sh'
	echo "# Installed by dante-via-backup.sh. Keeps mwan3 rule '$RULE' matching"
	echo "# $WANB_IF's current IPv4 address, so traffic sent from it leaves via $WANB_IF."
	echo "IFACE='$WANB_IF' RULE='$RULE' POLICY='$POLICY'"
	cat <<'EOF'
. /lib/functions/network.sh
network_flush_cache
network_get_ipaddr ip "$IFACE"
[ -n "$ip" ] || exit 0              # no address right now - keep the rule

changed=0
newip=0
[ "$(uci -q get "mwan3.$RULE")" = rule ] || { uci set "mwan3.$RULE=rule"; changed=1; }
for kv in family=ipv4 proto=all "use_policy=$POLICY" "src_ip=$ip"; do
	[ "$(uci -q get "mwan3.$RULE.${kv%%=*}")" = "${kv#*=}" ] && continue
	uci set "mwan3.$RULE.$kv"
	changed=1
	[ "${kv%%=*}" = src_ip ] && newip=1
done

# the rule only works in front of the catch-all default rule
pos() { uci show mwan3 | sed -n 's/^mwan3\.\([^.=]*\)=.*/\1/p' | grep -n -x "$1" | cut -d: -f1; }
p_rule=$(pos "$RULE")
p_def=$(pos default_rule_v4)
if [ -n "$p_def" ] && [ "$p_rule" -gt "$p_def" ]; then
	uci reorder "mwan3.$RULE=$((p_def - 1))"
	changed=1
fi

[ "$changed" = 1 ] || exit 0
uci commit mwan3
logger -t mwan3-backup-src "traffic from $ip now leaves via $IFACE (policy $POLICY)"
[ "$1" = --no-restart ] && exit 0
/etc/init.d/mwan3 running && /etc/init.d/mwan3 restart
# new address: restart dante so it binds to it
[ "$newip" = 1 ] && /etc/init.d/sockd running 2>/dev/null && /etc/init.d/sockd restart
exit 0
EOF
} >"$UPDATER"
chmod +x "$UPDATER"

cat >"$HOOK" <<EOF
# Installed by dante-via-backup.sh: follow $WANB_IF's address changes
[ "\$INTERFACE" = "$WANB_IF" ] || exit 0
case "\$ACTION" in
	ifup|ifupdate) $UPDATER ;;
esac
EOF
# sysupgrade keeps /etc/config but drops files it doesn't know about
for f in "$UPDATER" "$HOOK"; do
	grep -qx "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >>/etc/sysupgrade.conf
done
info "Installed $UPDATER and $HOOK (listed in /etc/sysupgrade.conf)"

# --- apply now ---------------------------------------------------------------
info "mwan3 rule '$RULE': traffic from $IP -> $WANB_IF ($POLICY); restarting mwan3..."
"$UPDATER" || die "Updating the mwan3 rule failed."

info "Waiting for mwan3 to report $WANB_IF online (up to 60 s)..."
t=0
while [ "$t" -lt 60 ]; do
	# "(online ..." = mwan3 itself uses it, not only the tracker saw it up
	mwan3 interfaces 2>/dev/null | grep -q "interface $WANB_IF is online.*(online" && break
	sleep 5
	t=$((t + 5))
done
mwan3 interfaces 2>/dev/null | grep "interface $WANB_IF "

if [ -x /etc/init.d/sockd ] && ! pidof sockd >/dev/null; then
	warn "sockd is not running - check its config with: sockd -V -f /etc/sockd.conf"
fi

network_get_ipaddr LAN_IP lan
cat <<EOF

Done. Only traffic sent from $IP (dante) uses $WANB_IF; the rest is unchanged.
  Test here      curl -s -x socks5h://127.0.0.1:1080 http://api.ipify.org; echo
  Test from PC   curl.exe -x socks5h://${LAN_IP:-192.168.1.1}:1080 https://api.ipify.org
                 -> the backup ISP's public IP (without -x: the main one)
  Rule counters  mwan3 rules
  Undo           sh $0 --remove
EOF

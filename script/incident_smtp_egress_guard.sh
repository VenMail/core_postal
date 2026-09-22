#!/bin/sh
# Temporary, reversible containment while the direct-SMTP review gate is unavailable.
# Install as /usr/local/sbin/venmail-smtp-egress-guard and run as root.
set -eu

case "${1:-}" in
  start|stop) action="$1" ;;
  *) echo 'usage: venmail-smtp-egress-guard start|stop' >&2; exit 2 ;;
esac

for family in iptables ip6tables; do
  for chain in DOCKER-USER OUTPUT; do
    set -- -o eth0 -p tcp -m multiport --dports 25,465,587 \
      -m comment --comment venmail-netcup-phishing-20260922-temporary-egress \
      -j REJECT
    if [ "$action" = start ]; then
      if ! "$family" -w -C "$chain" "$@" 2>/dev/null; then
        "$family" -w -I "$chain" 1 "$@"
      fi
    else
      while "$family" -w -C "$chain" "$@" 2>/dev/null; do
        "$family" -w -D "$chain" "$@"
      done
    fi
  done
done

{ stdenv, dnsServer }:
let
  useHostResolvConf = dnsServer == "" || dnsServer == "none";
  host_resolv_conf = if useHostResolvConf then
    builtins.path {
      name = "host-resolv-conf";
      path = "/etc/resolv.conf";
    }
  else
    null;
in stdenv.mkDerivation {
  name = "resolv-conf";
  buildCommand = ''
    RESOLV_CONF_FILE="$out/resolv.conf"
    mkdir -p $out

    ${if useHostResolvConf then ''
      is_host_resolve_conf_valid() {
        if [ ! -f "${host_resolv_conf}" ]; then
          return 1
        fi

        if grep -qE "nameserver\s+127\.0\.0\." "${host_resolv_conf}"; then
          return 1
        else
          return 0
        fi
      }

      if is_host_resolve_conf_valid; then
        cp ${host_resolv_conf} $RESOLV_CONF_FILE
        echo "resolv.conf is generated from the host's /etc/resolv.conf"
      else
        echo "Warning: the host's /etc/resolv.conf is not valid for the guest VM (containing lookback addresses)." >&2
        echo "Fall back to Google's public DNS servers (8.8.8.8)." >&2
        echo "Consider using the DNS_SERVER Makefile variable to specify DNS server explicitly." >&2
        echo "For example: make DNS_SERVER=\"192.168.1.1\"" >&2
        echo "nameserver 8.8.8.8" > "$RESOLV_CONF_FILE"
      fi
    '' else ''
      echo "nameserver ${dnsServer}" > "$RESOLV_CONF_FILE"
    ''}
  '';
}

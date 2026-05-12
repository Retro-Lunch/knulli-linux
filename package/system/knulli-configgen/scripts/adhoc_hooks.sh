#!/bin/bash

CHANNEL="6"
INTERFACE=$(knulli-wifi get_interface)

SSID=$(knulli-settings-get wifi.adhoc.ssid)
PASSPHRASE=$(knulli-settings-get wifi.adhoc.key)

adhoc_flag="/tmp/.adhoc_ap_enabled"

hostapd_pid="/tmp/hostapd.pid"
hostapd_conf="/tmp/hostapd.conf"

dnsmasq_pid="/tmp/dnsmasq.pid"
dnsmasq_leases="/tmp/dnsmasq.leases"

is_quickresume_boot() {
  local code
  code="$(curl -s --max-time 0.3 -o /dev/null -w "%{http_code}" \
          "http://127.0.0.1:1234/runningGame" 2>/dev/null)"

  [ "$code" = "000" ] # api isn't running with quickresume
}

should_start_ap() {
    if [ "$(knulli-settings-get global.netplay)" != "1" ] || [ "$(knulli-settings-get global.netplay.hotspot)" != "1" ]; then
        return 1
    fi

    if is_quickresume_boot; then
        return 1
    fi

    if [ -z "$INTERFACE" ]; then
        return 1
    fi

    if ip addr show "$INTERFACE" | grep -q 'inet '; then
        return 1
    fi

    return 0
}

should_join_adhoc() {
    # Check if netplay is enabled
    if [ "$(knulli-settings-get global.netplay)" != "1" ]; then
        return 1
    fi

    # Check if client mode (reading from netplay config if available)
    # This will be set when launching a game in client mode
    if [ -f /tmp/netplay_mode ]; then
        mode=$(cat /tmp/netplay_mode)
        if [ "$mode" != "client" ]; then
            return 1
        fi
    else
        return 1
    fi

    # Check if already connected to netplay hotspot
    current_ssid=$(iwgetid -r 2>/dev/null)
    if [[ "$current_ssid" =~ NETPLAY ]]; then
        return 1  # Already connected
    fi

    return 0
}

join_adhoc_hotspot() {
    # Scan for NETPLAY_AP
    local hotspot=$(iw dev "$INTERFACE" scan 2>/dev/null | \
        awk '/^BSS / {ssid=""}
             /SSID: / {
                 ssid = substr($0, index($0, "SSID: ") + 6)
                 if (ssid ~ /NETPLAY/) {print ssid; exit}
             }')

    if [ -z "$hotspot" ]; then
        echo "No NETPLAY hotspot found" >&2
        return 1
    fi

    # Create wpa_supplicant config
    local wpa_conf="/tmp/netplay_join.conf"
    cat > "$wpa_conf" <<EOF
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
    ssid="$hotspot"
    psk="$PASSPHRASE"
    key_mgmt=WPA-PSK
    priority=100
}
EOF

    # Stop existing wpa_supplicant
    pkill -f "wpa_supplicant.*$INTERFACE" 2>/dev/null
    sleep 0.5

    # Start wpa_supplicant
    wpa_supplicant -B -i "$INTERFACE" -c "$wpa_conf" -P /tmp/netplay_join.pid >/dev/null 2>&1

    # Wait for connection (max 10 seconds)
    for i in {1..20}; do
        if ip addr show "$INTERFACE" 2>/dev/null | grep -q 'inet '; then
            rm -f "$wpa_conf"
            echo "Connected to $hotspot" >&2
            return 0
        fi
        sleep 0.5
    done

    rm -f "$wpa_conf"
    echo "Failed to connect to $hotspot" >&2
    return 1
}

case $1 in
    gameStart)
        # Check if we should host an ad-hoc hotspot
        if should_start_ap; then
            touch "$adhoc_flag"

            ip link set "$INTERFACE" up
            ip addr flush dev "$INTERFACE"
            sleep 0.1
            ip addr add 192.168.4.1/24 dev "$INTERFACE"

            cat <<EOF > "$hostapd_conf"
interface=$INTERFACE
driver=nl80211
ssid=$SSID
channel=$CHANNEL
hw_mode=g
auth_algs=1
wpa=2
wpa_passphrase=$PASSPHRASE
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

            hostapd "$hostapd_conf" &
            echo $! > "$hostapd_pid"

            dnsmasq --interface="$INTERFACE" \
                    --bind-interfaces \
                    --dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,12h \
                    --dhcp-leasefile="$dnsmasq_leases" \
                    --no-resolv &
            echo $! > "$dnsmasq_pid"

            for i in {1..100}; do
                if iw dev "$INTERFACE" info | grep -q "type AP"; then
                    break
                fi
                sleep 0.1
            done
        # Check if we should join an ad-hoc hotspot (client mode)
        elif should_join_adhoc; then
            join_adhoc_hotspot
        fi
        ;;
    gameStop)
        if [ -f "$adhoc_flag" ]; then
            kill "$(cat "$hostapd_pid")"
            rm -f "$hostapd_pid"

            kill "$(cat "$dnsmasq_pid")"
            rm -f "$dnsmasq_pid"
            rm -f "$dnsmasq_leases"

            ip addr flush dev "$INTERFACE"
            rm -f "$adhoc_flag"
        fi

        # Clean up netplay join artifacts
        if [ -f /tmp/netplay_join.pid ]; then
            kill "$(cat /tmp/netplay_join.pid)" 2>/dev/null || true
            rm -f /tmp/netplay_join.pid
        fi
        rm -f /tmp/netplay_mode

        ;;
esac


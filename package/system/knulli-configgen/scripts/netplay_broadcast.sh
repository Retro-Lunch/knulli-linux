#!/bin/bash
# netplay_broadcast.sh - Host broadcast service for ad-hoc netplay discovery
# Broadcasts host IP, netplay port, ROM hash, and game name via UDP every 5 seconds

BROADCAST_PORT=55434
NETPLAY_PORT="${NETPLAY_PORT:-55435}"
HOST_IP="${HOST_IP:-192.168.4.1}"
BROADCAST_ADDR="192.168.4.255"
ROM_PATH="${ROM_PATH:-}"

# PID file for cleanup
PID_FILE="/tmp/netplay_broadcast.pid"

# Calculate ROM CRC32 hash
calculate_rom_hash() {
    if [ -z "$ROM_PATH" ] || [ ! -f "$ROM_PATH" ]; then
        echo "UNKNOWN"
        return
    fi

    # Try different CRC utilities
    if command -v crc32 >/dev/null 2>&1; then
        crc32 "$ROM_PATH" 2>/dev/null || echo "UNKNOWN"
    elif command -v cksum >/dev/null 2>&1; then
        # cksum outputs: CRC SIZE FILENAME, we want just CRC
        cksum "$ROM_PATH" 2>/dev/null | awk '{print $1}' || echo "UNKNOWN"
    else
        echo "UNKNOWN"
    fi
}

# Get game name from ROM path
get_game_name() {
    if [ -z "$ROM_PATH" ]; then
        echo "UNKNOWN"
    else
        basename "$ROM_PATH"
    fi
}

stop_broadcast() {
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null
        rm -f "$PID_FILE"
    fi
}

start_broadcast() {
    # Stop any existing broadcast
    stop_broadcast

    # Calculate ROM hash and get game name
    ROM_HASH=$(calculate_rom_hash)
    GAME_NAME=$(get_game_name)

    # Start broadcast loop in background
    (
        while true; do
            # Send broadcast packet: KNULLI-NETPLAY:IP:PORT:ROM_HASH:GAME_NAME
            BROADCAST_MSG="KNULLI-NETPLAY:${HOST_IP}:${NETPLAY_PORT}:${ROM_HASH}:${GAME_NAME}"
            echo "$BROADCAST_MSG" | \
                nc -u -b -w1 "$BROADCAST_ADDR" "$BROADCAST_PORT" 2>/dev/null || \
                echo "$BROADCAST_MSG" | \
                busybox nc -u -b -w1 "$BROADCAST_ADDR" "$BROADCAST_PORT" 2>/dev/null
            sleep 5
        done
    ) &

    # Save PID for cleanup
    echo $! > "$PID_FILE"
}

case "$1" in
    start)
        start_broadcast
        ;;
    stop)
        stop_broadcast
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac

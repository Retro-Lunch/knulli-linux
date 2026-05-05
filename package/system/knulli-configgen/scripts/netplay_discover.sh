#!/bin/bash
# netplay_discover.sh - Client discovery service for ad-hoc netplay
# Listens for host broadcast, validates ROM hash, and returns discovered IP

BROADCAST_PORT=55434
TIMEOUT=10
DEFAULT_IP="192.168.4.1"
ROM_PATH="${ROM_PATH:-}"

# Calculate local ROM CRC32 hash
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

discover_host() {
    # Calculate local ROM hash
    LOCAL_HASH=$(calculate_rom_hash)

    # Try to receive broadcast packet with timeout
    local discovered_data=""

    # Use nc or busybox nc to listen for UDP broadcast
    if command -v nc >/dev/null 2>&1; then
        discovered_data=$(timeout "$TIMEOUT" nc -u -l -p "$BROADCAST_PORT" 2>/dev/null | head -n1)
    elif command -v busybox >/dev/null 2>&1; then
        discovered_data=$(timeout "$TIMEOUT" busybox nc -u -l -p "$BROADCAST_PORT" 2>/dev/null | head -n1)
    fi

    # Parse broadcast packet: KNULLI-NETPLAY:IP:PORT:ROM_HASH:GAME_NAME
    if [ -n "$discovered_data" ] && echo "$discovered_data" | grep -q "KNULLI-NETPLAY"; then
        # Extract fields from packet
        HOST_IP=$(echo "$discovered_data" | cut -d':' -f2)
        HOST_PORT=$(echo "$discovered_data" | cut -d':' -f3)
        HOST_ROM_HASH=$(echo "$discovered_data" | cut -d':' -f4)
        HOST_GAME_NAME=$(echo "$discovered_data" | cut -d':' -f5-)

        # Validate ROM hash if both are available
        if [ "$LOCAL_HASH" != "UNKNOWN" ] && [ "$HOST_ROM_HASH" != "UNKNOWN" ]; then
            if [ "$LOCAL_HASH" != "$HOST_ROM_HASH" ]; then
                # ROM mismatch - print error to stderr
                echo "ERROR: ROM mismatch detected!" >&2
                echo "Host is playing: $HOST_GAME_NAME (Hash: $HOST_ROM_HASH)" >&2
                echo "Your ROM hash: $LOCAL_HASH" >&2
                echo "Please ensure you have the exact same ROM file as the host." >&2

                # Return default IP but indicate failure
                echo "$DEFAULT_IP"
                return 2
            fi
        fi

        # ROM matches or hash validation skipped - return discovered IP
        if [ -n "$HOST_GAME_NAME" ] && [ "$HOST_GAME_NAME" != "UNKNOWN" ]; then
            echo "Found host playing: $HOST_GAME_NAME" >&2
        fi
        echo "$HOST_IP"
        return 0
    else
        # No broadcast received - fallback to default IP
        echo "No host broadcast detected, using default IP" >&2
        echo "$DEFAULT_IP"
        return 1
    fi
}

# Run discovery
discover_host

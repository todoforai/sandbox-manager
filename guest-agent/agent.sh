#!/bin/bash
# Simple guest agent for sandbox VMs
# Listens on vsock and executes commands
#
# Protocol: length-prefixed JSON
# Request:  {"type": "exec", "command": "ls -la"}
# Response: {"output": "...", "exit_code": 0}

set -e

VSOCK_CID=2  # Host CID
VSOCK_PORT=5000

log() {
    echo "[agent] $*" >&2
}

# Read length-prefixed message
read_message() {
    # Read 4-byte length (little-endian)
    local len_bytes
    len_bytes=$(dd bs=1 count=4 2>/dev/null | xxd -p)
    if [ -z "$len_bytes" ]; then
        return 1
    fi
    
    # Convert to decimal (little-endian)
    local len=$((16#${len_bytes:6:2}${len_bytes:4:2}${len_bytes:2:2}${len_bytes:0:2}))
    
    # Read message
    dd bs=1 count="$len" 2>/dev/null
}

# Write length-prefixed message
write_message() {
    local msg="$1"
    local len=${#msg}
    
    # Write 4-byte length (little-endian)
    printf "\\x$(printf '%02x' $((len & 0xFF)))"
    printf "\\x$(printf '%02x' $(((len >> 8) & 0xFF)))"
    printf "\\x$(printf '%02x' $(((len >> 16) & 0xFF)))"
    printf "\\x$(printf '%02x' $(((len >> 24) & 0xFF)))"
    
    # Write message
    printf '%s' "$msg"
}

# Handle a single request
handle_request() {
    local request="$1"
    
    # Parse JSON (simple extraction)
    local type=$(echo "$request" | grep -oP '"type"\s*:\s*"\K[^"]+')
    local command=$(echo "$request" | grep -oP '"command"\s*:\s*"\K[^"]+')
    
    case "$type" in
        exec)
            log "Executing: $command"
            local output exit_code
            output=$(eval "$command" 2>&1) || true
            exit_code=$?
            
            # Escape output for JSON
            output=$(echo "$output" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g' | tr '\n' ' ')
            
            echo "{\"output\":\"$output\",\"exit_code\":$exit_code}"
            ;;
        ping)
            echo '{"pong":true}'
            ;;
        *)
            echo '{"error":"unknown command type"}'
            ;;
    esac
}

# Main loop using socat for vsock
main_socat() {
    log "Starting agent (socat mode) on vsock port $VSOCK_PORT"
    
    socat VSOCK-LISTEN:$VSOCK_PORT,fork EXEC:"$0 --handle",nofork
}

# Handle single connection (called by socat)
handle_connection() {
    while true; do
        local request
        request=$(read_message) || break
        
        local response
        response=$(handle_request "$request")
        
        write_message "$response"
    done
}

# Fallback: use netcat on serial console
main_serial() {
    log "Starting agent (serial mode)"
    
    while true; do
        # Read command from serial
        read -r line
        
        if [ -n "$line" ]; then
            # Execute and print output
            eval "$line" 2>&1 || true
            echo "---END---"
        fi
    done
}

# Entry point
case "${1:-}" in
    --handle)
        handle_connection
        ;;
    --serial)
        main_serial
        ;;
    *)
        # Check if socat is available
        if command -v socat &>/dev/null; then
            main_socat
        else
            log "socat not found, falling back to serial mode"
            main_serial
        fi
        ;;
esac

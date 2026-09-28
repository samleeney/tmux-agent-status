#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/session-status.sh"
source "$SCRIPT_DIR/lib/sidebar-clients.sh"
source "$SCRIPT_DIR/lib/completion-inbox.sh"

case "${1:-refresh}" in
    collect)
        touch "$REFRESH_FILE"
        ;;
    active)
        signal_sidebar_clients USR2 active
        ;;
    refresh|*)
        completion_ack_active
        signal_sidebar_clients USR1 all
        ;;
esac

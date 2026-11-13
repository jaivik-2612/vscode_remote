#!/bin/sh
# Adapted from Tails' tails-shell-library/tails-greeter.sh: the Welcome
# screen settings live under /var/lib/antumbra/settings/applied/ (root-owned
# copies made by antumbra-apply-welcome-settings) instead of
# /var/lib/live/config/. File format and keys are Tails': shell KEY=value.

ANTUMBRA_SETTINGS_APPLIED='/var/lib/antumbra/settings/applied'
MACSPOOF_SETTING="${ANTUMBRA_SETTINGS_APPLIED}/tails.macspoof"
NETWORK_SETTING="${ANTUMBRA_SETTINGS_APPLIED}/tails.network"
UNSAFE_BROWSER_SETTING="${ANTUMBRA_SETTINGS_APPLIED}/tails.unsafe-browser"

_get_tg_setting() {
    if [ -r "${1}" ]; then
        # shellcheck disable=SC1090
        . "${1}"
        eval "echo \${${2}:-}"
    fi
}

mac_spoof_is_enabled() {
    # Only return false when explicitly told so to increase failure safety.
    [ "$(_get_tg_setting "${MACSPOOF_SETTING}" TAILS_MACSPOOF_ENABLED)" != false ]
}

tails_network_enabled() {
    # Only return true when explicitly told so to increase failure safety.
    [ "$(_get_tg_setting "${NETWORK_SETTING}" TAILS_NETWORK)" = true ]
}

unsafe_browser_is_enabled() {
    [ "$(_get_tg_setting "${UNSAFE_BROWSER_SETTING}" TAILS_UNSAFE_BROWSER_ENABLED)" = true ]
}

#!/usr/bin/env bash
set -u

VM="${VM:-haos}"
URI="${URI:-qemu:///system}"
VIRSH="/usr/bin/virsh"
UDEVADM="/usr/bin/udevadm"
LOGGER="/usr/bin/logger"

: "${ZWAVE_SERIAL:?ZWAVE_SERIAL must be set in /etc/default/haos-usb-attach}"
: "${RFXCOM_SERIAL:?RFXCOM_SERIAL must be set in /etc/default/haos-usb-attach}"

EXPECTED_VID="10c4"
EXPECTED_PID="ea60"

log() {
    local msg="$*"
    echo "$(date '+%F %T') $msg"
    "$LOGGER" -t haos-usb-attach -- "$msg"
}

find_usb() {
    local wanted_serial="$1"
    local d serial

    for d in /sys/bus/usb/devices/*; do
        [[ -r "$d/serial" ]] || continue

        serial="$(tr -d '\r\n' < "$d/serial")"

        if [[ "$serial" == "$wanted_serial" ]]; then
            [[ -r "$d/busnum" ]] || return 1
            [[ -r "$d/devnum" ]] || return 1
            [[ -r "$d/idVendor" ]] || return 1
            [[ -r "$d/idProduct" ]] || return 1

            printf '%s %s %s %s %s\n' \
                "$(cat "$d/busnum")" \
                "$(cat "$d/devnum")" \
                "$(cat "$d/idVendor")" \
                "$(cat "$d/idProduct")" \
                "$(basename "$d")"

            return 0
        fi
    done

    return 1
}

vm_running() {
    "$VIRSH" -c "$URI" domid "$VM" >/dev/null 2>&1
}

already_attached() {
    local bus="$1"
    local dev="$2"

    "$VIRSH" -c "$URI" dumpxml "$VM" 2>/dev/null |
        grep -Fq "<address bus='$bus' device='$dev'/>"
}

attach_serial() {
    local name="$1"
    local wanted_serial="$2"
    local info bus dev vid pid syspath xml

    if ! info="$(find_usb "$wanted_serial")"; then
        log "$name: USB device with serial $wanted_serial not found"
        return 0
    fi

    read -r bus dev vid pid syspath <<< "$info"

    if [[ "$vid" != "$EXPECTED_VID" || "$pid" != "$EXPECTED_PID" ]]; then
        log "$name: serial matched but VID:PID is $vid:$pid, expected $EXPECTED_VID:$EXPECTED_PID - refusing attach"
        return 1
    fi

    if already_attached "$bus" "$dev"; then
        log "$name: already attached - USB $bus/$dev ($syspath), serial $wanted_serial"
        return 0
    fi

    xml="$(mktemp /run/haos-usb-XXXXXX.xml)"

    cat >"$xml" <<XML
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <address bus='$bus' device='$dev'/>
  </source>
</hostdev>
XML

    log "$name: attaching serial $wanted_serial from USB $bus/$dev ($syspath)"

    if "$VIRSH" -c "$URI" attach-device "$VM" "$xml" --live; then
        log "$name: attach successful"
        rm -f "$xml"
        return 0
    else
        log "$name: attach FAILED"
        rm -f "$xml"
        return 1
    fi
}

"$UDEVADM" settle --timeout=30 2>/dev/null || true

if ! vm_running; then
    log "HAOS VM is not running; will retry later"
    exit 0
fi

rc=0
attach_serial "Z-Wave" "$ZWAVE_SERIAL" || rc=1
attach_serial "RFXCOM" "$RFXCOM_SERIAL" || rc=1
exit "$rc"

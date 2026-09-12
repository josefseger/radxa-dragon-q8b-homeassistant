#!/usr/bin/env bash
set -u

printf '=== KERNEL ===\n'
uname -r

printf '\n=== EFI BOOT ===\n'
if command -v efibootmgr >/dev/null 2>&1; then
    sudo efibootmgr | sed -n '1,12p'
else
    echo 'efibootmgr not installed'
fi

printf '\n=== BOOT LOADER ===\n'
if command -v bootctl >/dev/null 2>&1; then
    sudo bootctl status 2>/dev/null | grep -E 'Product:|Loader:|Current Entry:' || true
else
    echo 'bootctl not installed'
fi

printf '\n=== KVM ===\n'
if [[ -e /dev/kvm ]]; then
    ls -l /dev/kvm
else
    echo 'FAIL: /dev/kvm is missing'
fi

printf '\n=== VHE ===\n'
if sudo dmesg 2>/dev/null | grep -F 'VHE mode initialized successfully'; then
    :
else
    echo 'FAIL: VHE success line not found in dmesg'
fi

printf '\n=== REMOTEPROCS ===\n'
shopt -s nullglob
rprocs=(/sys/class/remoteproc/remoteproc*)
if ((${#rprocs[@]} == 0)); then
    echo 'No remoteproc devices found'
else
    for r in "${rprocs[@]}"; do
        name=$(cat "$r/name" 2>/dev/null || echo '?')
        state=$(cat "$r/state" 2>/dev/null || echo '?')
        printf '%s: %s = %s\n' "$(basename "$r")" "$name" "$state"
    done
fi

printf '\n=== QEBSPIL MARKER ===\n'
if sudo test -e /boot/efi/qebspil-loaded.txt; then
    sudo ls -l /boot/efi/qebspil-loaded.txt
else
    echo 'qebspil marker not found'
fi

printf '\n=== IRIS VIDEO NODES ===\n'
if [[ -d /sys/class/video4linux ]]; then
    for v in /sys/class/video4linux/video*; do
        [[ -e "$v" ]] || continue
        printf '%s: %s\n' "$(basename "$v")" "$(cat "$v/name" 2>/dev/null || echo '?')"
    done
else
    echo 'No V4L2 video nodes found'
fi

printf '\n=== IRIS / FIRMWARE ERRORS ===\n'
sudo dmesg 2>/dev/null | grep -Ei \
  'qcom-iris|video-codec|video-firmware|firmware download failed|error -22 initializing firmware|iommu.*fault|arm-smmu.*fault' \
  | tail -80 || true

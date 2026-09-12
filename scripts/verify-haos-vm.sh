#!/usr/bin/env bash
set -u

VM_NAME="${1:-haos}"
HAOS_IP="${2:-}"

printf '=== HOST ===\n'
uname -a
uptime

printf '\n=== KVM ===\n'
ls -l /dev/kvm 2>/dev/null || true

printf '\n=== BRIDGE ===\n'
ip -br addr show br0 2>/dev/null || true
bridge link 2>/dev/null || true

printf '\n=== LIBVIRT ===\n'
systemctl is-active libvirtd 2>/dev/null || true
systemctl is-active virtqemud 2>/dev/null || true

printf '\n=== VM ===\n'
virsh -c qemu:///system list --all 2>/dev/null || true
virsh -c qemu:///system dominfo "$VM_NAME" 2>/dev/null | grep -E '^(Name|State|CPU.s|Max memory|Autostart):' || true

printf '\n=== VM NETWORK ===\n'
virsh -c qemu:///system domiflist "$VM_NAME" 2>/dev/null || true

printf '\n=== VM DISK ===\n'
virsh -c qemu:///system domblklist "$VM_NAME" 2>/dev/null || true

if [[ -n "$HAOS_IP" ]]; then
  printf '\n=== HAOS IP ===\n'
  ping -c 3 "$HAOS_IP" || true
  ip neigh show "$HAOS_IP" || true

  printf '\n=== HOME ASSISTANT HTTP ===\n'
  curl -sS -o /dev/null \
    -w 'HTTP %{http_code} - remote %{remote_ip}\n' \
    --connect-timeout 5 \
    "http://${HAOS_IP}/" || true
else
  printf '\nNo HAOS IP supplied. Usage: %s [vm-name] [haos-ip]\n' "$0"
fi

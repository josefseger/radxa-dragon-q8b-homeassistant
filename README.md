# Home Assistant on Radxa Dragon Q8B

This project documents a **Radxa Dragon Q8B** running **Home Assistant OS as an ARM64 KVM virtual machine** while Debian 13 remains the host operating system.

The full stack is now working and reboot-tested on real hardware.

## Current status

Verified on 2026-09-12:

- Debian 13 host on NVMe
- native EL2/VHE with KVM
- Qualcomm ADSP/CDSP working under EL2
- audio working
- automatic fan control working
- Iris VPU hardware video decoding working under EL2
- NetworkManager bridge `br0` working
- Home Assistant OS 18.2 running under KVM/libvirt
- 6 vCPU
- 8 GiB RAM
- 512 GiB sparse QCOW2 disk
- AArch64 UEFI via AAVMF
- VirtIO disk and network
- bridged LAN networking
- libvirt autostart enabled
- VM reboot verified
- complete Q8B host reboot verified

The Home Assistant deployment is documented in detail in [HAOS-KVM.md](HAOS-KVM.md).

---

## Hardware and software

- Radxa Dragon Q8B
- Qualcomm Snapdragon 8cx Gen 3 / SC8280XP
- 16 GB RAM
- NVMe SSD
- Debian 13 (Trixie)
- Radxa stock kernel baseline: `7.0.11-6-qcom`
- production EL2 test kernel: `7.0.11-6+q8bel2.2-qcom`
- BIOS: Radxa release `260825`
- BIOS setting: `Hypervisor Override = Enabled`
- QEMU/libvirt/KVM

---

# Platform bring-up summary

## EL2 / KVM

With `Hypervisor Override = Enabled`, Linux enters EL2 and KVM initializes successfully:

```text
kvm [1]: VHE mode initialized successfully
```

`/dev/kvm` is available and the host passes the KVM requirements used by the HAOS VM.

## Q8B boot chain

The original boot chain was:

```text
Qualcomm UEFI
  -> /EFI/BOOT/BOOTAA64.EFI
  -> Radxa embloader 0.7
  -> BLS entry
  -> Linux kernel + initrd + DTB
```

A separate Debian systemd-boot binary was installed as:

```text
/EFI/systemd/systemd-boot-real-aa64.efi
```

The original Radxa fallback files were deliberately kept untouched.

The verified production path is:

```text
Qualcomm UEFI
  -> Q8B real systemd-boot UEFI entry
  -> systemd-boot
  -> qebspil EFI driver
  -> 7.0.11-6+q8bel2.2-qcom
  -> EL2/VHE + KVM
```

## ADSP/CDSP with qebspil

The platform uses `stephan-gh/qebspil`, tested at commit:

```text
8e4d9e676a3b3afe136cda9b953a2139ff1a32d0
```

EFI driver:

```text
/boot/efi/EFI/systemd/drivers/qebspilaa64.efi
```

The EL2 device-tree overlay marks the Qualcomm remote processors for handoff:

```dts
&remoteproc_adsp {
    qcom,broken-reset;
};

&remoteproc_nsp0 {
    qcom,broken-reset;
};
```

Verified Linux state:

```text
remoteproc0: adsp = attached
remoteproc1: cdsp = attached
```

Audio and automatic fan control then work under EL2.

Local kernel work used during bring-up included:

```text
13227941a903  remoteproc minidump attach fix
4eb7a4ca155b  Q8B qebspil EL2 overlay
```

## Iris VPU under EL2

Iris originally failed through the normal Qualcomm PAS path under EL2.

The working solution uses a native-EL2/non-TZ firmware path with a dedicated firmware-context IOMMU mapping instead of PAS 9.

The Q8B EL2 device tree includes:

```dts
&iris {
    video-firmware {
        iommus = <&apps_smmu 0x2a02 0x400>;
    };
};
```

Local Iris implementation commit:

```text
15633b765056c03d71dee501b8cc83b2ed6ff500
media: iris: support non-TZ firmware boot on Q8B EL2
```

Verified devices:

```text
/dev/video0  qcom-iris-decoder
/dev/video1  qcom-iris-encoder
```

## FFmpeg P010 support

FFmpeg 7.1.5 needed a small V4L2M2M P010 fix for HEVC Main10 output from Iris.

The verified patch is included as:

```text
patches/ffmpeg-7.1.5-v4l2m2m-p010.patch
```

A 10-second 4K HEVC Main10 hardware decode test completed with:

```text
240 frames
~8.47x realtime
```

The patched FFmpeg library was used locally for testing; Debian's system FFmpeg libraries were not replaced.

---

# Home Assistant OS deployment

The HAOS stage is now complete.

Final VM configuration:

```text
Architecture: ARM64 / aarch64
Acceleration: KVM
HAOS:         18.2 Generic AArch64 QCOW2
CPU:          6 vCPU
RAM:          8 GiB
Disk:         512 GiB sparse QCOW2
Firmware:     UEFI / AAVMF
Disk bus:     VirtIO SCSI
Network:      VirtIO -> br0
Autostart:    enabled
```

The physical Ethernet interface is a Layer-2 port of `br0`. The Debian host owns its IPv4/IPv6 configuration on `br0`, and the HAOS VM connects directly to the physical LAN through a VirtIO interface.

Wi-Fi was deliberately kept active as a recovery path during bridge migration.

The HAOS image used was:

```text
haos_generic-aarch64-18.2.qcow2.xz
```

Verified SHA-256:

```text
2c3e1822a4d83498980708d45573da1b74bc25c0643510bf29937a1bf70b1134
```

The QCOW2 disk was expanded from 32 GiB to 512 GiB while remaining sparse; immediately after resize it consumed only about 428 MiB of physical host storage.

The VM was created with `virt-install`, AAVMF UEFI, `host-passthrough` CPU mode, VirtIO SCSI and `bridge=br0`.

After validation, libvirt autostart was enabled.

Both of the following were tested successfully:

1. reboot of the HAOS VM
2. full reboot of the Radxa Dragon Q8B host

After full host reboot, the verified state was:

```text
br0       UP
eth0      forwarding under br0
vnet0     forwarding under br0
libvirtd  active
haos      running
autostart enabled
HAOS ping working
HAOS HTTP 200
```

See [HAOS-KVM.md](HAOS-KVM.md) for the exact deployment procedure and commands.

---

# Verification scripts

- `scripts/verify-el2-platform.sh` — verifies EL2/KVM platform state
- `scripts/test-p010-hwdecode.sh` — tests the local P010 hardware decode path
- `scripts/verify-haos-vm.sh` — verifies bridge, libvirt VM and Home Assistant HTTP reachability

Example:

```bash
sudo scripts/verify-haos-vm.sh haos <HAOS-IP>
```

---

# Recovery / safety notes

The recovery path was intentionally preserved throughout development.

- Do not overwrite `/EFI/BOOT/BOOTAA64.EFI`.
- Do not overwrite the Radxa embloader `/EFI/systemd/systemd-bootaa64.efi`.
- Keep `/EFI/systemd/systemd-boot-real-aa64.efi` separate.
- Keep the stock kernel and normal Q8B DTB installed.
- Keep the stock BLS entry available.
- Keep the firmware Boot Manager entry available after the direct systemd-boot entry.
- Do not manually edit `extlinux.conf`; it is not the active normal boot path used here.
- BIOS `Hypervisor Override = Auto` plus the stock kernel remains the EL1 recovery configuration.
- Do not manually force fan PWM while `pwm1_enable=2`; that is automatic fan mode.
- Keep an independent recovery network path while converting Ethernet to a bridge.
- NetworkManager UUIDs, DHCP addresses, VM MAC addresses and UEFI boot IDs are installation-specific and should be discovered locally rather than copied blindly.

---

# Project status

**Platform bring-up and Home Assistant OS KVM deployment complete.**

The complete host + bridge + libvirt + HAOS stack has been tested successfully across both VM reboot and full Q8B host reboot.

This repository records fixes and procedures that were actually tested on the hardware. It is not a one-command installer, and the custom kernel/Iris work remains engineering work rather than an upstream-supported Radxa Q8B Home Assistant configuration.

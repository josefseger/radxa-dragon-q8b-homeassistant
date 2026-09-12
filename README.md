# Home Assistant on Radxa Dragon Q8B

This project documents the work needed to prepare a **Radxa Dragon Q8B** to run **Home Assistant OS in a KVM virtual machine** while keeping Debian as the host operating system.

The difficult platform work is now complete: the Q8B boots automatically into native EL2/VHE with KVM, Qualcomm ADSP/CDSP, audio, automatic fan control, and Iris VPU hardware video decoding all working together.

Home Assistant OS itself has **not yet been installed**. That is the next project step.

## Hardware and software used

- Radxa Dragon Q8B
- Qualcomm Snapdragon 8cx Gen 3 / SC8280XP
- 16 GB RAM
- NVMe SSD
- Debian 13 (Trixie)
- Radxa kernel baseline: `7.0.11-6-qcom`
- BIOS: Radxa release `260825`
- BIOS `Hypervisor Override = Enabled`

## Planned Home Assistant VM

- ARM64 Home Assistant OS
- KVM acceleration
- **6 vCPU**
- **8 GB RAM**
- **512 GB sparse qcow2** disk
- UEFI boot
- bridged Ethernet
- VM autostart

---

# Platform bring-up

## 1. Debian baseline

Debian Trixie was installed on NVMe and used as the normal desktop/host OS.

In the normal EL1 boot configuration the basic hardware worked, including Ethernet, Wi-Fi, Bluetooth, display, audio, fan control, and Iris video decoding.

Stock kernel:

```bash
uname -r
# 7.0.11-6-qcom
```

## 2. Enable EL2 / KVM

KVM/QEMU/libvirt/virt-manager were installed on Debian.

BIOS was updated to `260825`, then:

```text
Hypervisor Override = Enabled
```

Linux then enters EL2 and KVM initializes successfully:

```text
kvm [1]: VHE mode initialized successfully
```

and:

```bash
ls -l /dev/kvm
```

shows the KVM device.

### The first EL2 problem

With EL2 enabled, the Qualcomm ADSP and CDSP remote processors failed through the normal PAS path:

```text
qcom_q6v5_pas ... error -22 initializing firmware ...qcadsp8280.mbn
qcom_q6v5_pas ... error -22 initializing firmware ...qccdsp8280.mbn
```

This also broke audio and automatic fan control.

## 3. Understand the Q8B boot chain

The original boot chain was:

```text
Qualcomm UEFI
  -> /EFI/BOOT/BOOTAA64.EFI
  -> Radxa embloader 0.7
  -> BLS entry
  -> Linux kernel + initrd + DTB
```

Radxa's `embloader` is not normal Debian systemd-boot and does not automatically load EFI drop-in drivers from:

```text
/EFI/systemd/drivers/
```

The original fallback loader was kept untouched for recovery.

## 4. Add real Debian systemd-boot

A separate copy of Debian systemd-boot was installed as:

```text
/EFI/systemd/systemd-boot-real-aa64.efi
```

During development it was chainloaded from embloader. Once the platform was proven stable, a dedicated UEFI boot entry was created so Qualcomm UEFI can start it directly.

The original files remain untouched:

```text
/EFI/BOOT/BOOTAA64.EFI
/EFI/systemd/systemd-bootaa64.efi
```

## 5. Use qebspil for ADSP/CDSP

We used:

- project: `stephan-gh/qebspil`
- tested commit: `8e4d9e676a3b3afe136cda9b953a2139ff1a32d0`

EFI driver:

```text
/boot/efi/EFI/systemd/drivers/qebspilaa64.efi
```

The tested configuration uses qebspil only for the required Qualcomm remote processors. It is **not** built with `QEBSPIL_ALWAYS_START=1`.

The Q8B EL2 device-tree overlay marks ADSP and CDSP for takeover:

```dts
&remoteproc_adsp {
    qcom,broken-reset;
};

&remoteproc_nsp0 {
    qcom,broken-reset;
};
```

After Linux boots, they attach to the already running processors:

```text
remoteproc0: adsp = attached
remoteproc1: cdsp = attached
```

Audio works and the automatic fan controller works again.

The fan hwmon device is:

```text
radxa_svc_glink
```

with automatic mode:

```text
pwm1_enable = 2
```

## 6. Kernel remoteproc attach fix

The Radxa kernel already had most of the required pre-started remoteproc handoff support, but the Qualcomm minidump remoteproc operations used by ADSP were missing the attach callback.

Local kernel commits used during the bring-up:

```text
13227941a903  remoteproc minidump attach fix
4eb7a4ca155b  Q8B qebspil EL2 overlay
```

The first working KVM + DSP kernel was:

```text
7.0.11-6+q8bel2.1-qcom
```

This established the first major milestone:

```text
EL2/VHE + KVM + ADSP/CDSP + audio + automatic fan control
```

---

# Iris VPU under EL2

## 7. Why Iris originally failed

After ADSP/CDSP were fixed, the Qualcomm Iris VPU still failed under EL2:

```text
qcom-iris aa00000.video-codec: error -22 initializing firmware qcom/vpu/vpu20_p4_gen2_s6.mbn
```

The failure occurred before firmware authentication/reset in the Qualcomm PAS path for:

```text
IRIS_PAS_ID = 9
```

The same Iris hardware and firmware worked correctly in EL1, so this was an EL2/PAS integration problem rather than a hardware failure.

qebspil was deliberately **not** extended to Iris/PAS 9.

## 8. Non-TZ Iris firmware boot

The working solution follows the Qualcomm native-EL2/non-TZ firmware model used on compute platforms:

- detect a `video-firmware` child node
- use `qcom_mdt_load_no_init()` instead of PAS 9
- create a dedicated firmware-context IOMMU domain
- map the Iris firmware region into that domain
- perform the Iris/Xtensa reset sequence directly
- bypass PAS authentication/reset/memory-protection calls in non-TZ mode
- tear down the firmware IOMMU mapping on unload

The Q8B EL2 device tree adds:

```dts
&iris {
    video-firmware {
        iommus = <&apps_smmu 0x2a02 0x400>;
    };
};
```

The EL2 DTB composition therefore contains both:

- qebspil ADSP/CDSP handoff
- Iris non-TZ firmware context

The Iris implementation was committed locally as:

```text
15633b765056c03d71dee501b8cc83b2ed6ff500
media: iris: support non-TZ firmware boot on Q8B EL2
```

The resulting test package/kernel is:

```text
linux-image-7.0.11-6+q8bel2.2-qcom
7.0.11-6+q8bel2.2-qcom
```

During boot the dedicated firmware device is visible in its own IOMMU group:

```text
platform video-firmware.0: Adding to iommu group 31
```

The old Iris PAS 9 `-22` error is gone.

## 9. Iris decoder is available at EL2

With the `.2` kernel:

```text
/dev/video0  qcom-iris-decoder
/dev/video1  qcom-iris-encoder
```

and the decoder is provided by:

```text
qcom-iris
iris_driver
Iris Decoder
```

---

# FFmpeg P010 support

## 10. Missing P010 support in FFmpeg 7.1.5 V4L2M2M

A 4K HEVC Main10 test stream exposed two missing pieces in FFmpeg 7.1.5.

### Fix 1 - map V4L2 P010 to FFmpeg P010LE

In:

```text
libavcodec/v4l2_fmt.c
```

we add:

```c
#ifdef V4L2_PIX_FMT_P010
    { AV_FMT(P010LE),      AV_CODEC(RAWVIDEO),    V4L2_FMT(P010) },
#endif
```

### Fix 2 - handle single-memory-plane P010 like NV12

Iris exposes P010 as one V4L2 memory buffer containing the Y plane followed by interleaved UV.

FFmpeg already handled that layout for NV12/NV21. The same pointer/stride fixup is also needed for:

```c
case AV_PIX_FMT_P010LE:
```

The minimal verified patch is included here:

```text
patches/ffmpeg-7.1.5-v4l2m2m-p010.patch
```

We deliberately do **not** replace Debian's system FFmpeg libraries. The patched `libavcodec.so.61` is used locally for testing/mpv.

A later experimental V4L2 `.flush` full-reinitialization patch was tested and rejected. It is intentionally not included here.

## 11. HEVC Main10 hardware decoding works under EL2

The final `.2` EL2 kernel successfully opens the Iris hardware decoder through FFmpeg:

```text
Using device /dev/video0
driver 'iris_driver' on card 'Iris Decoder' in mplane mode
requesting formats: output=HEVC/none capture=NV12/yuv420p10le
```

The decoder outputs P010 at 3840x2160.

A 10-second 4K HEVC Main10 hardware decode test completed with:

```text
240 frames
~8.47x realtime
```

No Iris PAS 9 firmware failure, `firmware download failed`, or Iris IOMMU fault appeared.

The FFmpeg/V4L2 path did report one recoverable capture-buffer initialization/decode error during startup, but decoding continued and completed the requested 240 output frames. This remains worth monitoring during longer playback, but it no longer blocks the KVM/Home Assistant platform.

No test-media filenames are included in this repository.

---

# Automatic production boot

## 12. Direct UEFI boot to real systemd-boot

During development the working path required manual selection through embloader and then real systemd-boot.

That is no longer required.

A dedicated UEFI entry was created for:

```text
\EFI\systemd\systemd-boot-real-aa64.efi
```

Example command used on this machine:

```bash
sudo efibootmgr -C \
  -d /dev/nvme0n1 \
  -p 2 \
  -L "Q8B real systemd-boot" \
  -l '\EFI\systemd\systemd-boot-real-aa64.efi'
```

The entry was first tested safely with `BootNext`, then made permanent only after the automatic boot was verified.

On the tested machine the final UEFI order is:

```text
BootOrder: 0005,0004
Boot0005: Q8B real systemd-boot
Boot0004: BootManagerMenuApp
```

The numeric IDs are firmware-instance-specific and should **not** be copied blindly to another machine.

The `.2` BLS entry is the persistent systemd-boot default:

```text
RadxaOS-7.0.11-6+q8bel2.2-qcom.conf
```

while `loader.conf` deliberately still contains the stock kernel as the file-based recovery default:

```text
timeout 10
#console-mode keep
default RadxaOS-7.0.11-6-qcom.conf
```

The resulting normal boot path is now:

```text
Qualcomm UEFI
  -> Q8B real systemd-boot UEFI entry
  -> systemd-boot 257.13
  -> qebspil EFI driver
  -> 7.0.11-6+q8bel2.2-qcom
  -> EL2/VHE + KVM
```

Automatic reboot and cold-boot operation were validated without manually selecting a boot entry.

A successful platform verification shows:

```text
Kernel:       7.0.11-6+q8bel2.2-qcom
Boot loader:  systemd-boot-real-aa64.efi
KVM:          /dev/kvm present
VHE:          initialized successfully
ADSP:         attached
CDSP:         attached
qebspil:      loaded
```

---

# Current status

| Feature | EL1 / stock boot | EL2 / production test boot |
|---|---|---|
| Debian desktop | Working | Working |
| KVM `/dev/kvm` | No | **Working** |
| VHE | No | **Working** |
| ADSP | Working | **Working via qebspil + attach** |
| CDSP | Working | **Working via qebspil + attach** |
| Audio | Working | **Working** |
| Automatic fan control | Working | **Working** |
| Iris VPU firmware | Working | **Working via non-TZ firmware boot** |
| HEVC Main10 hardware decode | Working with P010 patch | **Working with P010 patch** |
| Automatic unattended boot | Stock path | **Working** |
| Home Assistant OS VM | Not installed | **Next milestone** |

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

# Next step: Home Assistant OS VM

The host platform is now considered ready for the Home Assistant stage.

Planned VM configuration:

```text
Architecture: ARM64
Acceleration: KVM
CPU:          6 vCPU
RAM:          8 GB
Disk:         512 GB sparse qcow2
Firmware:     UEFI
Network:      bridged Ethernet
Autostart:    enabled
```

The next work is:

1. create a NetworkManager bridge on the wired Ethernet interface while keeping Wi-Fi available as a recovery path
2. validate libvirt/KVM networking
3. create the Home Assistant OS ARM64 VM
4. enable VM autostart
5. validate reboot/power-loss recovery of the complete host + VM stack

# Project status

**Platform bring-up complete; Home Assistant VM installation next.**

This repository records fixes that were actually tested on the hardware. It is not yet a one-command installer and the custom kernel changes are still experimental/local engineering work rather than an upstream-supported Q8B configuration.

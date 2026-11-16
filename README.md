# Hardware H.264 encoding on macOS 26 (Tahoe) for AMD Tahiti GPUs

A three-byte patch that turns on the **VCE 1.0 hardware H.264 encoder** of AMD Tahiti-family GPUs
(the FirePro D300 / D500 / D700 of the Mac Pro Late 2013, and their desktop siblings) under
macOS 26 "Tahoe" running with [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher).

After the patch, VideoToolbox reports a hardware H.264 encoder and apps that ask for one get it:
Parsec hosting, `avconvert`, anything built on `VTCompressionSession` with
`RequireHardwareAcceleratedVideoEncoder`.

Without it, `VTCompressionSessionCreate` fails with `-12903` and everything falls back to software encoding.

> **Status:** works on the one configuration listed under [Tested on](#tested-on). It has **not** been tried on a
> bare-metal Mac Pro 2013. Reports welcome.

## What it changes

OCLP's *AMD Legacy GCN* root patch installs the AMD video plugin from macOS 12.5
(`/System/Library/Extensions/AMDRadeonVADriver.bundle`, version 4.8.101). The encoder code in that plugin
drives VCE 1.0 correctly, but two things keep macOS 26 from using it:

| # | File offset | Change | Why |
|---|---|---|---|
| 1 | `0x4de6` | `3f` → `7f` | The plugin does not advertise general-purpose H.264 encode (AVD function `0x20/0x800`) for Tahiti/Pitcairn/Verde. AppleGVA only accepts that function, so it rejects the GPU. The byte sets bit 22 of the family's capability mask. |
| 2 | `0x28c92` | `14` → `6c` | The plugin stores each frame's bit count at `stats+0x14` (macOS 12 layout). AppleGVA in macOS 26 reads it at `stats+0x6c`, sees 0 and delivers empty frames. |
| 3 | `0x28cab` | `14` → `6c` | Same store, in the alternative (packed) code path. |

No kernel extension is modified and no framework is replaced. The full story is in
[docs/how-it-works.md](docs/how-it-works.md).

## Tested on

- AMD FirePro D500 (`1002:679e`, Tahiti LE) from a Mac Pro Late 2013
- macOS 26.7.3 (25G342), SMBIOS `MacPro7,1`
- OpenCore Legacy Patcher 3.0.0-rc.5, *AMD Legacy GCN* root patch, AMFIPass 1.4.1 with `-amfipassbeta`
- `AMDRadeonVADriver` 4.8.101, MD5 of the unpatched binary: `867f4e42fa67b0bee8364122c2ac7358`
- The GPU was passed through to a virtual machine (Proxmox, SeaBIOS + OpenCore DUET), not running on bare metal

`apply.sh` checks the original bytes at every offset and refuses to touch anything if they differ, so on a
different build of the plugin it simply stops.

## Performance

Measured with [`tools/vtenc`](tools/vtenc.m) on the D500, real-time mode, Main profile:

| Resolution | Encoder alone (flat frames) | With a moving test pattern | Mean latency |
|---|---|---|---|
| 1280×720 | 82 fps | 60–68 fps | ~13 ms |
| 1600×900 | 67 fps | ~53 fps | ~23 ms |
| 1920×1080 | 47–49 fps | 37–40 fps | ~28 ms |

This looks like the hardware's ceiling rather than a tuning problem: Parsec on Windows, using AMD's own driver,
reports about 18 ms of encode latency per 1080p frame on the same card. VCE 1.0 limits also apply: H.264 only (no HEVC), no B-frames, at most
1920×1088.

## Install

You need a Mac that already boots macOS 26 with OCLP's root patches for this GPU (Metal working).

```bash
git clone https://github.com/Fedex2002/tahiti-vce-macos.git
```

```bash
cd tahiti-vce-macos
```

```bash
sudo zsh patch/apply.sh
```

Reboot.

**Real Mac Pro Late 2013 only.** AppleGVA has a hardcoded rule that gives board-id
`Mac-F60DEB81FF30ACF6` (MacPro6,1) no accelerator at all for H.264 encoding. It also has a preference that
overrides the rule. Run this once as your user (not with sudo), then log out and in:

```bash
defaults write com.apple.AppleGVA gvaForceAMDAVCEncode -bool YES
```

With a `MacPro7,1` or `iMacPro1,1` SMBIOS this is not needed.

The patch lives on the system volume. Re-running OCLP's root patcher or installing a macOS update puts the
original plugin back; run `apply.sh` again afterwards.

## Verify

Build the test tool (needs the Xcode Command Line Tools):

```bash
clang -fobjc-arc -O2 -o vtenc tools/vtenc.m -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Foundation -framework AVFoundation
```

```bash
./vtenc 1280 720 120 60 6000000 /tmp/vtenc.h264 rt
```

A working setup prints something like:

```
create rc=0
using hardware: YES
  parameter set 0: 26 bytes, nal type 7
  parameter set 1: 4 bytes, nal type 8
frame 0: 29532 bytes, nal: 5
frame 1: 24650 bytes, nal: 1
...
complete rc=0 | in=120 out=120 err=0 | 2971202 bytes | 59.7 fps
mp4: ok (/tmp/vtenc.mp4)
```

Open `/tmp/vtenc.mp4` to look at the result: a scrolling checkerboard with a white square moving across it.

Failure modes:

- `create rc=-12903`: no hardware encoder. Patch 1 is missing, or (real Mac Pro) the `defaults write` above.
- frames of exactly the bitstream buffer size (3,686,400 bytes at 720p) with `nal: BAD(0)`: patches 2/3 are missing.

## Revert

```bash
sudo zsh patch/revert.sh
```

Reboot. This restores the bundle saved in `/Users/Shared/tahiti-vce-backup` when the patch was applied.

## Headless Macs

A Mac with no monitor attached falls back to a 1280×1024 phantom display, which is what remote-desktop tools
then capture. [`tools/vdisplay.m`](tools/vdisplay.m) creates a virtual 1080p display (private
`CGVirtualDisplay` API) and [`tools/setres.m`](tools/setres.m) switches its mode. Given the numbers above,
1600×900 is a good balance for 60 fps streaming.

## Tools

| File | What it is |
|---|---|
| [`patch/apply.sh`](patch/apply.sh), [`patch/revert.sh`](patch/revert.sh) | The patch, with byte verification and a backup |
| [`tools/vtenc.m`](tools/vtenc.m) | Hardware-encoder test: encodes a generated pattern, prints per-frame sizes and latency, writes `.h264` and `.mp4` |
| [`tools/vdisplay.m`](tools/vdisplay.m), [`tools/setres.m`](tools/setres.m) | Virtual display for headless use, and a mode switcher |
| [`tools/gva.py`](tools/gva.py) | Small capstone-based disassembler for one image inside a dyld shared cache sub-file or a standalone Mach-O; used for the analysis |

## Caveats

- It modifies the system volume, like OCLP's own root patches. Have a backup or a snapshot you can boot.
- It relies on the SIP and AMFI configuration OCLP already sets up (the re-signed bundle is ad-hoc signed).
- Only the Tahiti-family capability mask is changed. The masks of the next GPU families in the plugin also lack
  the encode bit, so those cards would need their own one-byte change; that is not covered or tested here.
- No Apple or AMD binaries are distributed in this repository, only byte offsets.

## Credits

- [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher) (Dortania) for making these GPUs
  work on current macOS in the first place.
- [Lilu / WhateverGreen / AMFIPass](https://github.com/acidanthera) (Acidanthera, dhinakg).
- Mesa's `radeon_vce` driver, whose command and feedback layouts made it possible to recognise what the plugin
  sends to the hardware.

Not affiliated with Apple, AMD or the projects above. MIT licensed, see [LICENSE](LICENSE).

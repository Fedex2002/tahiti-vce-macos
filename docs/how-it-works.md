# How it works

Notes from tracking down why VideoToolbox would not use the VCE encoder of a FirePro D500 on macOS 26.7.3,
and what each byte of the patch does. Addresses are for macOS 26.7.3 (25G342): AppleGVA 113.56 inside
`dyld_shared_cache_x86_64.02` (image base `0x7FFA0D812000`), and `AMDRadeonVADriver` 4.8.101 as installed by
OCLP 3.0.0-rc.5 (file addresses, `__TEXT` at `0x7FFA1CB38000`).

## The pieces

```
app ── VideoToolbox ── VTEncoderXPCService
                          └─ AppleGVA.framework          (Apple: picks a GPU, drives the encoder "flow")
                               └─ AMDRadeonVADriver.bundle   (AMD plugin: capabilities, VCE command stream)
                                    └─ AMDRadeonX4000.kext   (kernel: VCE engine, firmware, channels)
```

On a Tahiti card under OCLP, the kernel extension and the plugin come from macOS 12.5. AppleGVA is the one
that ships with macOS 26. The two were never meant to meet.

## 1. Seeing the real error

`VTCompressionSessionCreate` with `RequireHardwareAcceleratedVideoEncoder` returns `-12903`, and the only
log line is generic:

```
GVA encoder error: AVFQTXENC_CreateInstance fails with error -12915, unsupported usage 0
```

"unsupported usage" is just the wording of the catch-all message; usage 0 (export) is supported. AppleGVA has
a hidden verbose switch that makes the silent failure paths talk:

```bash
defaults write com.apple.GVAEncoder gvaExporterInfo -string YES
```

With it:

```
GVA encoder error: fail to create encoder data path, accel idx : 0 (err=1))
```

So a GPU accelerator *is* found; creating the encoder on it is what fails.

## 2. Accelerator selection, and why the Mac Pro 2013 is excluded

The function that collects accelerators for a flow (`0x7FFA0D835BAC`; flow 11 is the H.264 encoder) walks the
loaded VA plugins and then switches on the board-id:

- `Mac-F60DEB81FF30ACF6` (MacPro6,1): if the flow is 11, return **no accelerator**. Hardware H.264 encoding is
  switched off by hand for this machine.
- `Mac-7BA5B2D9E42DDD94` (iMacPro1,1) and `Mac-27AD2F918AE68F61` (MacPro7,1): use the AMD accelerators.
- Anything else: Intel if present.

Before the switch it reads four preferences in the `com.apple.AppleGVA` domain: `gvaForceAMDAVCDecode`,
`gvaForceAMDAVCEncode`, `gvaForceAMDHEVCDecode`, `gvaForceAMDKE`. With `gvaForceAMDAVCEncode` set, flow 11
takes the AMD accelerator regardless of board-id (`GVA info: AVDGetGPUAccelerators, force AMD for flow_id 11`).
That is the escape hatch for a real Mac Pro 2013.

Spoofing the AppleGVA board-id to MacPro6,1 with WhateverGreen (`unfairgva=4 hwgva-id=Mac-F60DEB81FF30ACF6`)
is therefore the wrong move: it selects exactly the entry that disables encoding.

## 3. Patch 1: the capability the plugin does not advertise

Each accelerator exposes a list of *AVD functions*, identified by `(funcId, subId)`. The flow-11 object
(`Branch_Encoder1_AMD2`) only proceeds if it finds function `0x20/0x800`; otherwise it returns 1, which is
the `err=1` above.

In the plugin, `AvdCapability::initDriverCapability` builds that list from a static table of 41 functions.
A function is included only if its bit is set in a per-family capability mask filled in by
`VAAcceleratorInfo::getExtraIdInfo`:

| Index | funcId / subId | Engine | Required mask bit |
|---|---|---|---|
| 24 | `0x20 / 0x20` | VCE | 21 |
| 25 | `0x20 / 0x800` | VCE | 22 |
| 26 | `0x20 / 0x1000` | UVD/VCN (HEVC) | 25 |

| Family (from `VAAcceleratorInfo::identify`) | Mask | Bit 21 | Bit 22 |
|---|---|---|---|
| 0–2 (the Tahiti generation; `0x679e` lands here) | `0x043fff0d` | yes | **no** |
| 3–4 (device IDs `0x664x`–`0x665x`, among others) | `0x05bfff0d` | yes | no |
| 5–6 (device IDs `0x692x`–`0x693x`, among others) | `0x05bfff2f`, `0x05bfff6f` | yes | no |
| 7–8 | `0x037e616f` | yes | yes |

Function `0x20/0x20` is presumably what older AppleGVA versions asked for on these cards; the H.264 encoder
flow of macOS 26's AppleGVA only looks for `0x20/0x800`. Both functions create the same `VAAvcEncoder` and use the same VCE engine, so the fix is to
let the Tahiti family advertise `0x20/0x800` too:

```
0x7FFA1CB3CDE2   movabs rax, 0x200043fff0d   →   movabs rax, 0x200047fff0d
file offset 0x4de6:  3f → 7f
```

The rest of the mask already describes VCE 1.0 properly (for instance the B-picture bit, 23, is clear, and the
flag that enables the CABAC-error re-encode workaround is set), which is a good sign the encoder code was
written with this hardware in mind.

After this, the session is created (`rc=0`, `using hardware: YES`) and the kernel's `VCELLQ` channel counters
move. But every frame comes out as 3,686,400 zero bytes at 720p, and Parsec reports a bitrate of 0.

## 4. Patches 2 and 3: the bit count nobody reads

Attaching lldb to `VTEncoderXPCService` (the plugin has full C++ symbols) and stopping in
`AVDAvcEncDataProcessor::ProcessEncodeStatus` shows the VCE feedback entries. The layout matches the one in
Mesa's `radeon_vce`: dword 1 says a frame was produced, dword 3 is the offset in the bitstream ring, dword 4
the size.

```
frame 0:  status 0, has_data 1, offset 0x0000, size 0x7388
frame 1:  status 0, has_data 1, offset 0x7388, size 0x6050
```

And the bitstream buffer holds a perfectly good stream:

```
00 00 00 01 09 10   00 00 00 01 67 4d 00 1f ...   00 00 00 01 68 ee 38 80   00 00 00 01 65 ...
   AUD                 SPS (Main, level 3.1)          PPS                      IDR slice
```

So the hardware and the VCE 1.0 firmware accept the plugin's command stream as it is. The data is lost one
step later. `Branch_Encoder1_AMD2::outputFrame` (`0x7FFA0D8A4052`) asks a small getter for the frame's size
in bits; that getter (`0x7FFA0D8BDCCA`) returns `stats[0x6c]`. The 12.5 plugin writes the value at
`stats[0x14]`:

```
0x7FFA1CB60C88   lea  ecx, [rax*8]          ; size in bits
0x7FFA1CB60C8F   mov  [r15+0x14], ecx       ; macOS 12 layout
```

AppleGVA reads 0, takes its `outputFrame byte_count = 0` error path (that message never shows up in the unified
log) and hands an empty buffer upstream. Changing the displacement makes the plugin write where macOS 26 looks:

```
file offset 0x28c8f:  41 89 4f 14  →  41 89 4f 6c      (0x28c92: 14 → 6c)
file offset 0x28ca8:  41 89 4f 14  →  41 89 4f 6c      (0x28cab: 14 → 6c)
```

The second store is the variant used when the size is packed together with another feedback field; it was
not exercised in testing but targets the same slot.

The stats structure is allocated by AppleGVA, which already reads offset `0x6c`, so the write stays inside it.

## 5. Things that turned out not to matter

- **`IOGVAEncoderRestricted = "VCE"`** on the accelerator node (set by `AMDRadeonX4000`). AppleGVA 113.56 does
  not read it. Encoding works with the property in place.
- **Board-id spoofing for AppleGVA.** Not needed with a MacPro7,1 SMBIOS; harmful with the MacPro6,1 id.
- **Motion-estimation settings.** The plugin's `0x04000007` packet can be edited at run time (quarter-pel off,
  smaller search range); output size changes, throughput does not.
- **VCE clocks.** `VCEPowerManagement::setPowerState` already selects the fastest clock state on AC power.
- **CABAC re-encode.** `VAAvcEncoder::reEncodeOnCabacError` never fired: 60 frames, 60 submissions.

A profile of the encoder process shows about 92 % of the time spent in `VAEncoder::waitForStatusEvent`,
waiting for the hardware. The remaining gap to 60 fps at 1080p is VCE 1.0 itself.

## 6. Reproducing the analysis

Static part, on any machine with Python and capstone:

```bash
python3 tools/gva.py AMDRadeonVADriver macho sym 'AvdCapability'
```

```bash
python3 tools/gva.py AMDRadeonVADriver macho func 7ffa1cb80598
```

```bash
python3 tools/gva.py dyld_shared_cache_x86_64.02 7FFA0D812000 str 'GVA encoder'
```

The AppleGVA image base and the sub-file that contains it come from `dyld_shared_cache_x86_64.map`, next to
the cache in `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/`.

Dynamic part: debugging `VTEncoderXPCService` needs `CSR_ALLOW_TASK_FOR_PID` on top of what OCLP sets
(`csr-active-config` `0x807` instead of `0x803`) and lldb from the Command Line Tools, run as root:

```
process attach --name VTEncoderXPCService --waitfor
breakpoint set -n "AVDAvcEncDataProcessor::ProcessEncodeStatus"
breakpoint set -s AppleGVA -a 0x7ffa0d8a4052
```

Start the attach first, then launch `vtenc`; the XPC service is spawned per client.

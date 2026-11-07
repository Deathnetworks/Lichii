# The Intel tensor stand-in

Ocarina of Time and other Switch games run an upscaler network on the GPU. The
network's matrix multiplies are native programs that Intel's Vulkan drivers reject or
cannot compile, so the emulator falls back to emulating them on the CPU.

That fallback is very slow. On an Arc Pro B70 with Intel's proprietary Windows
driver:

* the frame time was 89 ms (11-12 FPS) and 10-15 ms on black screens,
* the process held 5.9 GB of resident memory,
* the Vulkan call log showed no copy at all, so nothing was moved between RAM and
  VRAM; the GPU was idle 80-90 ms per frame while the CPU emulated the network,
* the Compute engine stayed at 0% because the network never reached the GPU.

Mesa's Intel driver is just as slow, so it already used the upscale stand-in: a
plain, filtered copy of the input frame to the output resolution instead of the
network. The stand-in gives up the network's own sharpening, which is the trade for
the frame rate.

## What runs where

| Driver | Driver ID | Behaviour |
| --- | --- | --- |
| Mesa Intel (Linux, and the open-source driver on Windows) | `VK_DRIVER_ID_INTEL_OPEN_SOURCE_MESA` | Upscale stand-in. |
| Intel proprietary Windows driver (Arc Pro B70, B580) | `VK_DRIVER_ID_INTEL_PROPRIETARY_WINDOWS` | Upscale stand-in. |
| Everything else | | The native programs are emulated as before. |

Donkey Kong Bananza keeps its native programs: rejecting them leaves the screen
purple from the mode select.

## Comparing the two paths

`EDEN_NX2_INTEL_TENSOR_STANDIN=1` forces the stand-in and `=0` forces the software
emulation on any driver, so both paths can be measured on one build. The log says
which one is in use:

```
Intel driver 'Intel(R) Arc(TM) Pro B70 Graphics': native tensor programs are
rejected, the upscale stand-in draws (EDEN_NX2_INTEL_TENSOR_STANDIN=unset)
```

The setting is process-local and changes nothing in the saved configuration.

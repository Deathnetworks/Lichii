# Building Lichii on Windows

There are two ways to get a Windows x86_64 build: the GitHub Actions release workflow
(this repository's own `release-binaries.yml`) and a local build with
`tools/windows/build-windows.ps1`. The local script does everything from an empty
folder to a zip, so it also works on a machine that has never built the project.

## Quick start

1. Install **Visual Studio 2022** with the **Desktop development with C++** workload.
   The script cannot install this silently; it checks for it and tells you when it is
   missing.
2. Install **Python 3** (tick *Add python.exe to PATH*) and **Git**.
3. Open a normal PowerShell window and run:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File tools/windows/build-windows.ps1
   ```

   The script creates `lichii-windows-build` next to where it was started. Use
   `-Root C:\build\lichii` to put it somewhere else and `-Jobs 12` to pick the number
   of parallel compile jobs (the default is half of the logical cores).

4. Open the PowerShell window again as **Administrator** when the script asks for it
   to install the Vulkan SDK, or install the Vulkan SDK yourself from
   <https://vulkan.lunarg.com/sdk/home> and run the script again.

The build takes roughly 30 to 60 minutes on a modern CPU. When it finishes,
`lichii-windows-build/lichii-windows-x86_64.zip` holds the binaries together with
their runtime dependencies, so it can be unpacked and run on another machine.

## What the script does

| Step | What happens |
| --- | --- |
| Prepare | Creates the build folder, clones the repository, adds the upstream remote and fetches both. |
| Merge | Merges `upstream/nx2` when it is ahead, and checks that the Intel tensor stand-in is present. |
| Prerequisites | Installs the missing CMake, Ninja, sccache, LLVM 22.1.8, the Vulkan SDK 1.4.341.1 and Qt 6.8.3 (win64_msvc2022_64 with the qtcharts module). |
| Configure | Uses the same clang-cl, ThinLTO and CMake flags as the `windows-x86_64` CI job. |
| Build | Compiles `yuzu`, `yuzu-cmd` and `lichii-updater`. |
| Deploy | Runs `windeployqt` so the Qt runtime sits next to `lichii.exe`. |
| Package | Writes the zip. |

Useful switches:

| Switch | Effect |
| --- | --- |
| `-SkipPrerequisites` | Only check the prerequisites, install nothing. |
| `-SkipMerge` | Do not merge the upstream branch. |
| `-SkipDeploy` | Do not run `windeployqt`; the binaries then need a Qt install on the target machine. |
| `-Pgo` | Build the PGO variant with the committed Ocarina of Time profile. |

## Intel GPUs and the upscale stand-in

Intel's graphics drivers cannot run the game's native tensor network (Ocarina of Time
has 768 matrix multiplies in it), so the emulator emulates it on the CPU. On an
Arc Pro B70 that emulation cost 89 ms per frame (11-12 FPS) and 5.9 GB of resident
memory while the GPU sat idle. Both Intel driver families now use the upscale
stand-in instead, which draws the frame directly; see
[Intel tensor stand-in](IntelTensorStandIn.md).

Set `EDEN_NX2_INTEL_TENSOR_STANDIN=0` before starting the emulator to compare
against the old software emulation, and `=1` to force the stand-in.

## GitHub Actions instead

The repository's `release-binaries.yml` workflow builds the same way on the
`windows-2022` runner and attaches the archives to a release. Run it from the
Actions tab with *Run workflow*, or push to the `nx2-experimental` branch to trigger
it. The `windows-x86_64` asset is the normal build and `windows-x86_64-pgo` adds the
Ocarina of Time profile.

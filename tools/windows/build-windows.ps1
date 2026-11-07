# SPDX-License-Identifier: GPL-3.0-or-later

<#
.SYNOPSIS
    Builds Lichii for Windows x86_64 on a clean machine, from an empty folder to a zip.

.DESCRIPTION
    The script does the whole job:

      1. creates a blank build folder,
      2. clones the repository and adds the upstream remote,
      3. merges the upstream nx2 branch and checks that the Intel tensor stand-in is in,
      4. checks the prerequisites and installs the missing ones (CMake, Ninja, sccache,
         LLVM, the Vulkan SDK and Qt 6.8.3),
      5. configures the same clang-cl + ThinLTO build the CI uses,
      6. compiles it,
      7. deploys the Qt runtime with windeployqt,
      8. writes a zip with the binaries and their runtime dependencies.

    Run it from a PowerShell window. Visual Studio 2022 with "Desktop development with
    C++" has to be installed already (it cannot be installed silently here); the script
    says how to get it when it is missing. Installing the Vulkan SDK needs an elevated
    shell, and the script says so when it gets there.

.PARAMETER Root
    The blank folder the build lives in. Everything else is created inside it.

.PARAMETER Repo
    The repository to clone.

.PARAMETER Upstream
    The upstream repository whose nx2 branch is merged in.

.PARAMETER Branch
    The branch to build.

.PARAMETER Jobs
    Parallel compile jobs. 0 picks half of the logical cores.

.PARAMETER SkipPrerequisites
    Do not install anything, only check.

.PARAMETER SkipMerge
    Do not merge the upstream branch.

.PARAMETER SkipDeploy
    Do not run windeployqt (the binaries then miss the Qt runtime).

.PARAMETER Pgo
    Build the PGO variant with the committed Ocarina of Time profile.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File tools/windows/build-windows.ps1

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File tools/windows/build-windows.ps1 -Root C:\build\lichii -Jobs 12
#>

[CmdletBinding()]
param(
    [string] $Root = (Join-Path (Get-Location) 'lichii-windows-build'),
    [string] $Repo = 'https://github.com/Deathnetworks/Lichii.git',
    [string] $Upstream = 'https://github.com/zortos293/Lichii.git',
    [string] $Branch = 'nx2',
    [string] $QtVersion = '6.8.3',
    [int] $Jobs = 0,
    [switch] $SkipPrerequisites,
    [switch] $SkipMerge,
    [switch] $SkipDeploy,
    [switch] $Pgo
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$LlvmVersion = '22.1.8'
$LlvmSha256 = '16e5709785fef73c854646241c4a92c5cd574318d1b33c63330dd7721903e55c'
$VulkanSdkVersion = '1.4.341.1'

function Write-Step {
    param([string] $Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-Note {
    param([string] $Text)
    Write-Host "    $Text" -ForegroundColor DarkGray
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)] [string] $File,
        [string[]] $Arguments = @(),
        [string] $WorkingDirectory = (Get-Location).Path
    )
    Write-Note "> $File $($Arguments -join ' ')"
    Push-Location $WorkingDirectory
    try {
        & $File @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$File failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

function Test-Command {
    param([string] $Name)
    return [bool] (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Python {
    foreach ($candidate in 'python', 'python3', 'py') {
        if (Test-Command $candidate) {
            return $candidate
        }
    }
    throw 'Python 3 was not found. Install it from https://www.python.org/downloads/windows/ (tick "Add python.exe to PATH").'
}

function Install-PythonTool {
    param([string] $Package)
    $python = Get-Python
    Write-Note "installing $Package with $python -m pip"
    Invoke-Native $python @('-m', 'pip', 'install', '--user', '--upgrade', $Package)
    $scripts = Join-Path $env:APPDATA 'Python'
    if (Test-Path $scripts) {
        $env:PATH = $scripts + [IO.Path]::PathSeparator + $env:PATH
    }
}

if ($Jobs -le 0) {
    $Jobs = [Math]::Max(1, [Math]::Floor((Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors / 2))
}

Write-Host 'Lichii Windows build' -ForegroundColor Green
Write-Note "build folder : $Root"
Write-Note "repository   : $Repo"
Write-Note "upstream     : $Upstream ($Branch)"
Write-Note "parallel jobs: $Jobs"

# ---------------------------------------------------------------------------
# 1. The blank folder and the sources
# ---------------------------------------------------------------------------
Write-Step 'Preparing the build folder and the sources'

if (-not (Test-Command 'git')) {
    throw 'Git was not found. Install it from https://git-scm.com/download/win and run the script again.'
}

New-Item -ItemType Directory -Force -Path $Root | Out-Null
$Source = Join-Path $Root 'src'
if (Test-Path (Join-Path $Source '.git')) {
    Write-Note 'source tree already present, reusing it'
} else {
    if (Test-Path $Source) {
        Remove-Item -Recurse -Force $Source
    }
    Invoke-Native 'git' @('clone', '--recurse-submodules', $Repo, $Source)
}

if (git -C $Source remote get-url upstream 2>$null) {
    Invoke-Native 'git' @('-C', $Source, 'remote', 'set-url', 'upstream', $Upstream) $Source
} else {
    Invoke-Native 'git' @('-C', $Source, 'remote', 'add', 'upstream', $Upstream) $Source
}
Invoke-Native 'git' @('-C', $Source, 'fetch', '--tags', 'upstream') $Source
Invoke-Native 'git' @('-C', $Source, 'fetch', '--tags', 'origin') $Source
Invoke-Native 'git' @('-C', $Source, 'checkout', $Branch) $Source

# ---------------------------------------------------------------------------
# 2. The upstream merge and the Intel fix
# ---------------------------------------------------------------------------
if (-not $SkipMerge) {
    Write-Step 'Merging the upstream nx2 branch'
    $behind = (git -C $Source rev-list --count "HEAD..upstream/$Branch" | Select-Object -First 1)
    Write-Note "upstream/$Branch is $behind commit(s) ahead"
    if ([int] $behind -gt 0) {
        Invoke-Native 'git' @('-C', $Source, 'merge', '--no-edit', "upstream/$Branch") $Source
    } else {
        Write-Note 'already up to date'
    }
}

Write-Step 'Checking that the Intel tensor stand-in is in place'
$gate = Select-String -Path (Join-Path $Source 'src/video_core/renderer_vulkan/vk_rasterizer.cpp') -Pattern 'VK_DRIVER_ID_INTEL_PROPRIETARY_WINDOWS' -Quiet
if (-not $gate) {
    throw 'The Intel proprietary driver stand-in is missing from this checkout. Merge the branch that carries it and run the script again.'
}
Write-Note 'the proprietary Intel driver uses the upscale stand-in'

# ---------------------------------------------------------------------------
# 3. The prerequisites
# ---------------------------------------------------------------------------
Write-Step 'Checking the prerequisites'

foreach ($tool in 'cmake', 'ninja') {
    if (-not (Test-Command $tool)) {
        if ($SkipPrerequisites) {
            throw "$tool was not found and -SkipPrerequisites was given"
        }
        Write-Note "$tool is missing, installing it with pip"
        Install-PythonTool $tool
    }
}

$python = Get-Python
if (-not (Test-Command 'aqt')) {
    if ($SkipPrerequisites) {
        throw 'aqtinstall was not found and -SkipPrerequisites was given'
    }
    Write-Note 'aqtinstall is missing, installing it'
    Install-PythonTool 'aqtinstall'
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw 'Visual Studio 2022 was not found. Install it from https://visualstudio.microsoft.com/downloads/ with the "Desktop development with C++" workload, then run the script again.'
}
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) {
    throw 'Visual Studio 2022 with the "Desktop development with C++" workload was not found. Install that workload and run the script again.'
}
Write-Note "Visual Studio: $vs"

# The MSVC headers, libraries and SDK have to be on PATH before CMake runs.
& (Join-Path $Source 'tools/windows/load-msvc-env.ps1')

# LLVM (clang-cl, lld-link, llvm-lib), the same release the CI installs.
$llvmRoot = Join-Path $Root 'llvm'
if (-not (Test-Path (Join-Path $llvmRoot 'bin/clang-cl.exe'))) {
    if ($SkipPrerequisites) {
        throw 'LLVM was not found and -SkipPrerequisites was given'
    }
    Write-Note "installing LLVM $LlvmVersion"
    $installer = Join-Path $Root 'llvm-installer.exe'
    Invoke-WebRequest -OutFile $installer "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/LLVM-$LlvmVersion-win64.exe"
    if ((Get-FileHash -Algorithm SHA256 $installer).Hash -ne $LlvmSha256) {
        throw 'LLVM installer checksum mismatch'
    }
    Start-Process -Wait -FilePath $installer -ArgumentList '/S', "/D=$llvmRoot"
}
$env:LLVM_ROOT = $llvmRoot
Write-Note "LLVM: $llvmRoot"

# The Vulkan SDK, for glslang and the shader tooling.
$vulkanSdk = $env:VULKAN_SDK
if (-not $vulkanSdk) {
    $vulkanSdk = "C:/VulkanSDK/$VulkanSdkVersion"
}
if (-not (Test-Path $vulkanSdk)) {
    if ($SkipPrerequisites) {
        throw 'The Vulkan SDK was not found and -SkipPrerequisites was given'
    }
    if (-not (Test-Administrator)) {
        throw "The Vulkan SDK is not installed. Run this script from an elevated PowerShell window, or install the Vulkan SDK $VulkanSdkVersion from https://vulkan.lunarg.com/sdk/home and run it again."
    }
    Write-Note 'installing the Vulkan SDK, this takes a few minutes'
    Push-Location $Root
    try {
        & (Join-Path $Source 'tools/windows/install-vulkan-sdk.ps1')
    } finally {
        Pop-Location
    }
}
$env:VULKAN_SDK = $vulkanSdk
$env:PATH = (Join-Path $vulkanSdk 'Bin') + [IO.Path]::PathSeparator + $env:PATH
Write-Note "Vulkan SDK: $vulkanSdk"

# sccache keeps rebuilds quick; the build works without it.
if (-not (Test-Command 'sccache')) {
    if (-not $SkipPrerequisites) {
        Write-Note 'installing sccache'
        $zip = Join-Path $Root 'sccache.zip'
        Invoke-WebRequest -OutFile $zip 'https://github.com/mozilla/sccache/releases/download/v0.19.0/sccache-v0.19.0-x86_64-pc-windows-msvc.zip'
        Expand-Archive -Force $zip -DestinationPath (Join-Path $Root 'sccache')
        $bin = (Get-ChildItem -Recurse -Filter sccache.exe (Join-Path $Root 'sccache')).DirectoryName
        $env:PATH = $bin + [IO.Path]::PathSeparator + $env:PATH
    }
}

# Qt, the same version and architecture the CI uses.
$qtRoot = Join-Path $Root 'qt'
$qtDir = Join-Path $qtRoot "$QtVersion/msvc2019_64"
if (-not (Test-Path (Join-Path $qtDir 'bin/windeployqt.exe'))) {
    if ($SkipPrerequisites) {
        throw "Qt $QtVersion was not found and -SkipPrerequisites was given"
    }
    Write-Note "downloading Qt $QtVersion (win64_msvc2022_64, qtcharts)"
    Invoke-Native $python @('-m', 'aqt', 'install-qt', 'windows', 'desktop', $QtVersion, 'win64_msvc2022_64', '-m', 'qtcharts', '-O', $qtRoot)
}
Write-Note "Qt: $qtDir"

# ---------------------------------------------------------------------------
# 4. Configure
# ---------------------------------------------------------------------------
Write-Step 'Configuring the build'

$buildDir = Join-Path $Source 'build/release'
$flags = '-DWIN32 -D_WINDOWS -DNOMINMAX -flto=thin'
if ($Pgo) {
    $profile = Join-Path $Source 'lichii-windows.profdata'
    if (-not (Test-Path $profile)) {
        throw "The PGO profile $profile is missing from the checkout."
    }
    $flags += " -fprofile-use=$($profile.Replace('\', '/'))"
    $flags += ' -Wno-error=profile-instr-out-of-date -Wno-error=profile-instr-unprofiled'
    $flags += ' -Wno-error=backend-plugin'
}

$cmakeArgs = @(
    '-S', $Source,
    '-B', $buildDir,
    '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DBUILD_TESTING=OFF',
    '-DYUZU_TESTS=OFF',
    '-DYUZU_CMD=ON',
    '-DYUZU_ROOM=OFF',
    '-DYUZU_ROOM_STANDALONE=OFF',
    '-DYUZU_USE_BUNDLED_QT=OFF',
    '-DYUZU_USE_BUNDLED_SDL3=ON',
    '-DENABLE_UPDATE_CHECKER=ON',
    "-DLICHII_BUILD_TAG=build-$(Get-Date -Format yyyyMMdd)",
    '-DLICHII_BUILD_PLATFORM=windows-x86_64',
    '-DUSE_DISCORD_PRESENCE=OFF',
    "-DCMAKE_PREFIX_PATH=$qtDir",
    "-DCMAKE_C_COMPILER=$llvmRoot/bin/clang-cl.exe",
    "-DCMAKE_CXX_COMPILER=$llvmRoot/bin/clang-cl.exe",
    "-DCMAKE_LINKER=$llvmRoot/bin/lld-link.exe",
    "-DCMAKE_AR=$llvmRoot/bin/llvm-lib.exe",
    "-DCMAKE_C_FLAGS=$flags",
    "-DCMAKE_CXX_FLAGS=-EHsc $flags"
)
if (Test-Command 'sccache') {
    $cmakeArgs += '-DCMAKE_C_COMPILER_LAUNCHER=sccache'
    $cmakeArgs += '-DCMAKE_CXX_COMPILER_LAUNCHER=sccache'
}
Invoke-Native 'cmake' $cmakeArgs

# ---------------------------------------------------------------------------
# 5. Build
# ---------------------------------------------------------------------------
Write-Step "Building with $Jobs job(s), this takes a while"
Invoke-Native 'cmake' @('--build', $buildDir, '--target', 'yuzu', 'yuzu-cmd', 'lichii-updater', '--parallel', $Jobs)

# ---------------------------------------------------------------------------
# 6. Deploy the runtime and zip it
# ---------------------------------------------------------------------------
$binDir = Join-Path $buildDir 'bin'
foreach ($exe in 'lichii.exe', 'eden-cli.exe') {
    if (-not (Test-Path (Join-Path $binDir $exe))) {
        throw "$exe was not produced in $binDir"
    }
}

if (-not $SkipDeploy) {
    Write-Step 'Deploying the Qt runtime'
    $windeployqt = Join-Path $qtDir 'bin/windeployqt.exe'
    Invoke-Native $windeployqt @('--release', '--no-translations', (Join-Path $binDir 'lichii.exe'))
}

Write-Step 'Writing the zip'
$zipName = if ($Pgo) { 'lichii-windows-x86_64-pgo.zip' } else { 'lichii-windows-x86_64.zip' }
$zip = Join-Path $Root $zipName
if (Test-Path $zip) {
    Remove-Item -Force $zip
}
Compress-Archive -Path (Join-Path $binDir '*') -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Note "binaries : $binDir"
Write-Note "zip      : $zip"
Write-Note "source   : $Source"
Write-Host ''
Write-Note 'Intel GPUs (Arc Pro B70, B580) run the upscale stand-in by default.'
Write-Note 'Set EDEN_NX2_INTEL_TENSOR_STANDIN=0 to compare against the software emulation.'

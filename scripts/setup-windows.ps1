<#
.SYNOPSIS
    Installs the Windows build prerequisites of Ardoise into one folder of your choice.

.DESCRIPTION
    Installs, under -Root:

      cmake\        portable CMake
      ninja\        portable Ninja
      uv\           uv, its managed Python and its cache, used only to run aqtinstall
      Qt\           the Qt 6 MSVC desktop kit, with Widgets, SVG and the Linguist tools
      BuildTools\   Visual Studio Build Tools with the C++ workload, unless an existing
                    Visual Studio installation already has the MSVC x64 tools
      ardoise-env.ps1  dot-source it to open an MSVC developer shell with everything on PATH

    Each step is skipped when its result is already there, so the script can be run again.
    Nothing is added to the user's or the machine's environment variables.

    The Visual Studio Installer itself and the Windows SDK always go to the system drive:
    Microsoft does not let them be relocated. Installing the Build Tools asks for elevation.

.PARAMETER Root
    Folder that receives the prerequisites, for example D:\deps. Asked for when omitted.

.PARAMETER QtVersion
    Qt version to install (default: the version the CI builds with on Windows).

.PARAMETER SkipBuildTools
    Do not install Visual Studio Build Tools, even when no MSVC installation is found.

.PARAMETER DryRun
    Print what would be installed, without downloading or installing anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Root D:\deps
    . D:\deps\ardoise-env.ps1
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
#>
[CmdletBinding()]
param(
    [string] $Root,
    [string] $QtVersion = '6.8.3',
    [switch] $SkipBuildTools,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$CMakeVersion = '3.31.6'
$NinjaVersion = '1.12.1'
$UvVersion = '0.8.0'
$AqtVersion = '3.3.0'
$QtArch = 'win64_msvc2022_64'
$QtKit = 'msvc2022_64'
$MsvcComponent = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'

function Say([string] $Message) { Write-Host "ardoise-setup: $Message" }

function Get-File([string] $Url, [string] $Destination) {
    Say "downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

# Checks a download against the checksum file published next to it in the same release.
function Assert-Sha256([string] $File, [string] $ChecksumUrl, [string] $Name) {
    $sums = (Invoke-WebRequest -Uri $ChecksumUrl -UseBasicParsing).Content
    if ($sums -is [byte[]]) { $sums = [Text.Encoding]::ASCII.GetString($sums) }
    $expected = $null
    foreach ($line in ($sums -split "`n")) {
        $fields = $line.Trim() -split '\s+'
        if ($fields.Count -ge 2 -and $fields[1].TrimStart('*') -eq $Name) { $expected = $fields[0] }
        elseif ($fields.Count -eq 1 -and $fields[0] -match '^[0-9a-fA-F]{64}$') { $expected = $fields[0] }
    }
    if (-not $expected) { throw "no checksum for $Name in $ChecksumUrl" }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $File).Hash
    if ($actual -ne $expected.ToUpperInvariant()) { throw "checksum mismatch for $Name" }
}

function Expand-Download([string] $Url, [string] $Destination, [string] $ChecksumUrl) {
    $name = Split-Path $Url -Leaf
    $zip = Join-Path $script:Downloads $name
    Get-File $Url $zip
    if ($ChecksumUrl) { Assert-Sha256 $zip $ChecksumUrl $name }
    Expand-Archive -Path $zip -DestinationPath $Destination -Force
}

function Find-Msvc {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    $path = & $vswhere -latest -products * -requires $MsvcComponent -property installationPath
    if ($path) { return ($path | Select-Object -First 1).Trim() }
    return $null
}

if (-not $Root) {
    $default = Join-Path $env:SystemDrive 'ardoise-deps'
    $answer = Read-Host "Folder for the Ardoise build prerequisites [$default]"
    $Root = if ($answer) { $answer } else { $default }
}
$Root = [IO.Path]::GetFullPath($Root)

$CMakeDir = Join-Path $Root "cmake\cmake-$CMakeVersion-windows-x86_64"
$NinjaDir = Join-Path $Root 'ninja'
$UvDir = Join-Path $Root 'uv'
$QtDir = Join-Path $Root "Qt\$QtVersion\$QtKit"
$BuildToolsDir = Join-Path $Root 'BuildTools'
$EnvScript = Join-Path $Root 'ardoise-env.ps1'
$script:Downloads = Join-Path $Root 'downloads'

$vsPath = Find-Msvc
Say "prerequisites folder: $Root"
Say "CMake $CMakeVersion -> $CMakeDir"
Say "Ninja $NinjaVersion -> $NinjaDir"
Say "Qt $QtVersion ($QtKit) -> $QtDir, through uv $UvVersion and aqtinstall $AqtVersion"
if ($vsPath) { Say "MSVC: using the existing installation in $vsPath" }
elseif ($SkipBuildTools) { Say 'MSVC: not found, and -SkipBuildTools was given' }
else { Say "MSVC: Visual Studio Build Tools -> $BuildToolsDir" }
if ($DryRun) { Say 'dry run: nothing was installed'; exit 0 }

New-Item -ItemType Directory -Force -Path $Root, $script:Downloads | Out-Null

# CMake
if (Test-Path (Join-Path $CMakeDir 'bin\cmake.exe')) { Say 'CMake already installed' }
else {
    $base = "https://github.com/Kitware/CMake/releases/download/v$CMakeVersion"
    Expand-Download "$base/cmake-$CMakeVersion-windows-x86_64.zip" (Join-Path $Root 'cmake') "$base/cmake-$CMakeVersion-SHA-256.txt"
}

# Ninja (its releases publish no checksum file)
if (Test-Path (Join-Path $NinjaDir 'ninja.exe')) { Say 'Ninja already installed' }
else {
    Expand-Download "https://github.com/ninja-build/ninja/releases/download/v$NinjaVersion/ninja-win.zip" $NinjaDir $null
}

# uv, kept with its Python, tools and cache under the prerequisites folder
$uv = Join-Path $UvDir 'uv.exe'
if (Test-Path $uv) { Say 'uv already installed' }
else {
    $url = "https://github.com/astral-sh/uv/releases/download/$UvVersion/uv-x86_64-pc-windows-msvc.zip"
    Expand-Download $url $UvDir "$url.sha256"
}
$env:UV_CACHE_DIR = Join-Path $UvDir 'cache'
$env:UV_PYTHON_INSTALL_DIR = Join-Path $UvDir 'python'
$env:UV_TOOL_DIR = Join-Path $UvDir 'tools'
$env:UV_PYTHON_PREFERENCE = 'only-managed'

# Qt: the default archives of the kit include Widgets, SVG and the Linguist tools.
if (Test-Path (Join-Path $QtDir 'lib\cmake\Qt6\Qt6Config.cmake')) { Say "Qt $QtVersion already installed" }
else {
    $qtRoot = Join-Path $Root 'Qt'
    New-Item -ItemType Directory -Force -Path $qtRoot | Out-Null
    Push-Location $qtRoot
    try {
        & $uv tool run --from "aqtinstall==$AqtVersion" aqt install-qt windows desktop $QtVersion $QtArch --outputdir $qtRoot
        if ($LASTEXITCODE -ne 0) { throw "aqtinstall failed with exit code $LASTEXITCODE" }
    }
    finally { Pop-Location }
}

# MSVC
if (-not $vsPath -and -not $SkipBuildTools) {
    $installer = Join-Path $script:Downloads 'vs_BuildTools.exe'
    Get-File 'https://aka.ms/vs/17/release/vs_BuildTools.exe' $installer
    $signature = Get-AuthenticodeSignature $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw 'vs_BuildTools.exe is not signed by Microsoft'
    }
    Say 'installing Visual Studio Build Tools; this asks for elevation and takes a while'
    $arguments = @('--installPath', "`"$BuildToolsDir`"", '--add', 'Microsoft.VisualStudio.Workload.VCTools',
        '--includeRecommended', '--passive', '--wait', '--norestart')
    $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
    # 3010: installed, a restart is required.
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "Visual Studio Build Tools installer failed with exit code $($process.ExitCode)"
    }
    if ($process.ExitCode -eq 3010) { Say 'Visual Studio Build Tools installed; restart Windows before building' }
    $vsPath = Find-Msvc
    if (-not $vsPath) { throw 'MSVC x64 tools not found after installing Visual Studio Build Tools' }
}

# Developer shell script
$envContent = @'
# Generated by Ardoise's scripts/setup-windows.ps1. Dot-source it in PowerShell:
#   . "__ENV_SCRIPT__"
$vsPath = '__VS_PATH__'
if ($vsPath) {
    # VsDevCmd calls vswhere.exe through PATH.
    $env:PATH = (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer') + ';' + $env:PATH
    Import-Module (Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
} else {
    Write-Warning 'No MSVC installation was recorded; run this from a Visual Studio developer shell.'
}
$env:PATH = '__CMAKE_BIN__;__NINJA_DIR__;__QT_BIN__;' + $env:PATH
$env:CMAKE_PREFIX_PATH = '__QT_DIR__'
Write-Host 'Ardoise developer shell: MSVC x64, CMake, Ninja and Qt __QT_VERSION__ are ready.'
'@
$vsValue = if ($vsPath) { $vsPath } else { '' }
$envContent = $envContent.Replace('__ENV_SCRIPT__', $EnvScript).Replace('__VS_PATH__', $vsValue).
    Replace('__CMAKE_BIN__', (Join-Path $CMakeDir 'bin')).Replace('__NINJA_DIR__', $NinjaDir).
    Replace('__QT_BIN__', (Join-Path $QtDir 'bin')).Replace('__QT_DIR__', $QtDir).Replace('__QT_VERSION__', $QtVersion)
Set-Content -Path $EnvScript -Value $envContent -Encoding UTF8

Remove-Item -Recurse -Force $script:Downloads
Say 'done. Open a build shell with:'
Say "  . `"$EnvScript`""
Say '  cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug'

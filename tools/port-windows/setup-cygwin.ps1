<#
.SYNOPSIS
    Install the Cygwin toolchain Poplog needs on Windows.

.DESCRIPTION
    Downloads Cygwin's installer from cygwin.com, checks its code signature,
    and installs Cygwin with the packages a Poplog build uses.  It does not
    need administrator rights, adds nothing to the Start menu or desktop, and
    changes no system settings.  Running it again adds any missing packages
    and updates the rest.

    See INSTALL-WINDOWS.md for the whole procedure.

.PARAMETER Root
    Where to install Cygwin.  Default C:\cygwin64.

.PARAMETER Minimal
    Install only what a console build needs (no C++ compiler, so no
    graphics; no OpenSSL, pcre2 or curl headers, so no LIB CRYPTO, LIB PCRE
    or LIB HTTP_CLIENT).

.PARAMETER Site
    Cygwin mirror to download from.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\port-windows\setup-cygwin.ps1
#>
param(
    [string]$Root = 'C:\cygwin64',
    [switch]$Minimal,
    [string]$Site = 'https://mirrors.kernel.org/sourceware/cygwin/'
)

$ErrorActionPreference = 'Stop'

# What each group is for:
#   build     configure, make, the C compiler and assembler, ncurses for VED
#   graphics  g++ for the Dear ImGui backend (./configure --experimental-graphics)
#   libraries headers for the optional shims: LIB CRYPTO, LIB PCRE, LIB HTTP_CLIENT
#   tools     git for tools/fetch-imgui.sh; perl and curl for the test runners;
#             gdb for when something goes wrong; python3 for the pop11
#             skill's popsession
$build     = 'gcc-core', 'binutils', 'make', 'libncurses-devel'
$graphics  = 'gcc-g++'
$libraries = 'libssl-devel', 'libpcre2-devel', 'libcurl-devel', 'libsqlite3-devel', 'pkg-config'
$tools     = 'git', 'perl', 'curl', 'gdb', 'python3'

$packages = $build
if (-not $Minimal) { $packages = $build + $graphics + $libraries + $tools }

$work = Join-Path $env:TEMP 'poplog-cygwin-setup'
New-Item -ItemType Directory -Force $work | Out-Null
$setup = Join-Path $work 'setup-x86_64.exe'

Write-Host "Downloading the Cygwin installer ..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri 'https://cygwin.com/setup-x86_64.exe' -OutFile $setup -UseBasicParsing

$sig = Get-AuthenticodeSignature $setup
if ($sig.Status -ne 'Valid') {
    throw "The downloaded installer's signature is '$($sig.Status)', not Valid.  Not running it."
}
Write-Host "Installer signed by: $($sig.SignerCertificate.Subject)"

Write-Host "Installing Cygwin to $Root with: $($packages -join ', ')"
Write-Host "(a few minutes; the installer shows its own progress window)"
$arguments = @(
    '--no-admin', '--quiet-mode', '--no-desktop', '--no-shortcuts', '--no-startmenu',
    '--root', $Root,
    '--local-package-dir', (Join-Path $work 'packages'),
    '--site', $Site,
    '--packages', ($packages -join ',')
)
$p = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "The Cygwin installer exited with status $($p.ExitCode)." }

$bash = Join-Path $Root 'bin\bash.exe'
if (-not (Test-Path (Join-Path $Root 'bin\gcc.exe'))) { throw "gcc was not installed; see the installer's log in $Root\var\log." }

Write-Host ""
Write-Host "Done.  Open a Cygwin shell with:"
Write-Host "    $bash --login"
Write-Host "Your Windows drives are under /cygdrive, e.g. /cygdrive/c/Users/$env:USERNAME"
Write-Host "Next: INSTALL-WINDOWS.md, step 3 (the seed)."

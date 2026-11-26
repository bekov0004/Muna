# Builds Muna from this repository and installs it for the current user.
#   powershell -ExecutionPolicy Bypass -File windows\scripts\install.ps1 [-NoStart] [-NoLogin] [-Firewall]
# Needs the .NET 10 SDK (winget install Microsoft.DotNet.SDK.10). No administrator rights are needed,
# except for -Firewall (a rule that lets other computers send files with LocalSend).
param(
    [switch]$NoStart,
    [switch]$NoLogin,
    [switch]$Firewall
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$target = Join-Path $env:LOCALAPPDATA 'Programs\Muna'
$exe = Join-Path $target 'Muna.exe'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue) -or -not ((dotnet --list-sdks) -match '^10\.')) {
    Write-Host 'The .NET 10 SDK is needed to build Muna. Install it with:' -ForegroundColor Yellow
    Write-Host '    winget install Microsoft.DotNet.SDK.10'
    Write-Host 'then open a new terminal and run this script again.'
    exit 1
}

Write-Host 'Building Muna...'
$out = Join-Path $env:TEMP 'muna-build'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
dotnet publish (Join-Path $root 'Muna\Muna.csproj') -c Release -r win-x64 --self-contained `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
    -o $out --nologo -v quiet
if ($LASTEXITCODE -ne 0) { Write-Host 'The build failed (the lines above say why).' -ForegroundColor Red; exit 1 }

# a running Muna holds the file
Get-Process Muna -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | ForEach-Object { $_.Kill(); $_.WaitForExit(5000) }
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item (Join-Path $out 'Muna.exe') $exe -Force

# the Start menu
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Muna.lnk'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($menu)
$link.TargetPath = $exe
$link.WorkingDirectory = $target
$link.Description = 'Muna: a Dynamic Island for Windows'
$link.Save()

# open at login (Settings -> General -> System can turn it off)
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($NoLogin) { Remove-ItemProperty -Path $run -Name 'Muna' -ErrorAction SilentlyContinue }
else { Set-ItemProperty -Path $run -Name 'Muna' -Value "`"$exe`"" }

# uninstalling from Settings -> Apps
$uninstall = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Muna'
New-Item -Path $uninstall -Force | Out-Null
$script = Join-Path $target 'uninstall.ps1'
Copy-Item (Join-Path $PSScriptRoot 'uninstall.ps1') $script -Force
Set-ItemProperty -Path $uninstall -Name 'DisplayName' -Value 'Muna'
Set-ItemProperty -Path $uninstall -Name 'DisplayIcon' -Value $exe
Set-ItemProperty -Path $uninstall -Name 'Publisher' -Value 'Muna'
Set-ItemProperty -Path $uninstall -Name 'InstallLocation' -Value $target
Set-ItemProperty -Path $uninstall -Name 'UninstallString' -Value "powershell.exe -ExecutionPolicy Bypass -File `"$script`""
Set-ItemProperty -Path $uninstall -Name 'NoModify' -Value 1 -Type DWord
Set-ItemProperty -Path $uninstall -Name 'NoRepair' -Value 1 -Type DWord

if ($Firewall) {
    $rule = "netsh advfirewall firewall delete rule name=Muna-LocalSend >nul & " +
            "netsh advfirewall firewall add rule name=Muna-LocalSend dir=in action=allow protocol=TCP localport=53317 profile=private & " +
            "netsh advfirewall firewall add rule name=Muna-LocalSend dir=in action=allow protocol=UDP localport=53317 profile=private"
    Start-Process cmd.exe -ArgumentList '/c', $rule -Verb RunAs -Wait
}

Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Muna is installed in $target" -ForegroundColor Green
if (-not $NoStart) { Start-Process $exe }

# Removes Muna for the current user. Your notes, to-dos, clipboard and the rest stay in
# %APPDATA%\Muna unless -Purge is given.
#   powershell -ExecutionPolicy Bypass -File windows\scripts\uninstall.ps1 [-Purge]
param([switch]$Purge)
$ErrorActionPreference = 'Continue'
$target = Join-Path $env:LOCALAPPDATA 'Programs\Muna'
$exe = Join-Path $target 'Muna.exe'
Get-Process Muna -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | ForEach-Object { $_.Kill(); $_.WaitForExit(5000) }
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Muna' -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Muna' -Recurse -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'Muna.lnk') -ErrorAction SilentlyContinue
# this script may itself be in the folder: remove the rest, then the folder after it ends
Get-ChildItem $target -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'uninstall.ps1' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Start-Process cmd.exe -ArgumentList '/c', "timeout /t 2 >nul & rmdir /s /q `"$target`"" -WindowStyle Hidden
if ($Purge) {
    Remove-Item (Join-Path $env:APPDATA 'Muna') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:LOCALAPPDATA 'Muna') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Muna and its data are removed.'
} else {
    Write-Host "Muna is removed. Your data stays in $(Join-Path $env:APPDATA 'Muna')."
}

# ============================================================
#  WinSetup Studio - bootstrap.ps1
#  Едноредов стартер от интернет (спартански вариант):
#    irm https://raw.githubusercontent.com/MalinchevART/WinSetupStudio/main/bootstrap.ps1 | iex
#  Сваля файловете в %TEMP%\WinSetupStudio, стартира helper-а и
#  отваря приложението. За ПЪЛНИ права (админ) използвай пълния
#  пакет (WinSetupStudio-Portable.exe / WinSetupStudio.bat).
# ============================================================
param([switch]$Keep)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$base = 'https://raw.githubusercontent.com/MalinchevART/WinSetupStudio/main'
$dir = Join-Path $env:TEMP 'WinSetupStudio'
New-Item -ItemType Directory -Path $dir -Force | Out-Null

Write-Host '== WinSetup Studio: свалям файловете... ==' -ForegroundColor Cyan
foreach ($f in 'WinSetupStudio.html', 'WinSetupStudio-Server.ps1', 'Export-WinSettings.ps1', 'Make-SetupUSB.ps1', 'Get-WindowsIso.ps1') {
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "$base/$f" -OutFile (Join-Path $dir $f)
}
Write-Host ('  Готово -> ' + $dir) -ForegroundColor Green

Write-Host 'Стартирам помощника и приложението...' -ForegroundColor Cyan
Start-Process powershell -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $dir 'WinSetupStudio-Server.ps1'),
    '-Port', '8891') -WindowStyle Minimized

Start-Sleep -Seconds 2
Write-Host ''
Write-Host '== ГОТОВО! Приложението е отворено. ==' -ForegroundColor Green
Write-Host ('Файловете са в: ' + $dir + $(if ($Keep) { '  (-Keep: остават)' } else { '  (TEMP - ще изчезнат с почистването)' }))
Write-Host 'Бележка: без админ "Прочети този комп" е частичен. Пълния пакет: Releases на репото.'

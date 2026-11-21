# ============================================================
#  WinSetup Studio - Export-WinSettings.ps1 (v2)
#  Чете настройките на ТЕКУЩИЯ компютър и записва JSON профил,
#  който after това се импортира в WinSetupStudio.html
#  („Импорт профил от JSON" бутон / drag&drop върху приложението).
#
#  Употреба (PowerShell, без нужда от админ за основните данни):
#    powershell -ExecutionPolicy Bypass -File .\Export-WinSettings.ps1
#  Опционално: -OutPath "D:\profiles\mypc.json"
#  Администратор добавя и: компоненти (Hyper-V/WSL...), BitLocker,
#  диск/партиции информация.
# ============================================================
[CmdletBinding()]
param(
    [string]$OutPath = "$env:USERPROFILE\Desktop\WinSetupStudio-profile.json"
)

$ErrorActionPreference = 'SilentlyContinue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-UnattendBuild([string]$productName, [string]$displayVersion, [string]$buildNumber) {
    # Целева версия в терминологията на WinSetup Studio.
    # ВНИМАНИЕ: ProductName остава "Windows 10 Pro" дори на Windows 11 (legacy
    # стойност), затова гледаме НОМЕРА на build-а: 22000+ = Windows 11.
    $major = 0
    if ($buildNumber -match '^(\d+)\.') { $major = [int]$Matches[1] }
    if ($major -lt 22000) { return 'win10' }
    switch ($displayVersion) {
        '26H2' { return '26H2' }
        '25H2' { return '25H2' }
        '24H2' { return '24H2' }
        '23H2' { return '23H2' }
        '22H2' { return '22H2' }
        default { return '25H2' }
    }
}

Write-Host '== WinSetup Studio: четене на настройки ==' -ForegroundColor Cyan

# ---------- Основна информация (без админ) ----------
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$editionId    = $cv.EditionID                    # напр. Professional
$productName  = $cv.ProductName                  # напр. Windows 11 Pro (legacy стойност!)
$displayVer   = $cv.DisplayVersion               # напр. 25H2
$buildNumber  = "$($cv.CurrentBuildNumber).$($cv.UBR)"

$uiLang    = (Get-UICulture).Name               # език на интерфейса, напр. bg-BG
$sysLocale = (Get-WinSystemLocale).Name         # SystemLocale
$usrLocale = (Get-Culture).Name                 # UserLocale (формати, валута)
$timeZone  = (Get-TimeZone).Id                  # напр. "FLE Standard Time" за България

# Клавиатурни подредби -> формат "0402:00000402;0409:00000409"
$tips = @()
Get-WinUserLanguageList | ForEach-Object { $tips += $_.InputMethodTips }
$inputLocale = ($tips | Select-Object -Unique) -join ';'

$settings = [ordered]@{
    computername = $env:COMPUTERNAME
    username     = $env:USERNAME
    uilanguage   = $uiLang
    userlocale   = $usrLocale
    systemlocale = $sysLocale
    inputlocale  = $inputLocale
    timezone     = $timeZone
    edition      = $editionId
    targetversion = ConvertTo-UnattendBuild $productName $displayVer $buildNumber
}

$computer = [ordered]@{
    name          = $env:COMPUTERNAME
    productName   = $productName
    edition       = $editionId
    displayVersion= $displayVer
    build         = $buildNumber
}

# ---------- Хардуер (без админ) ----------
$cpu   = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$gpus  = @((Get-CimInstance Win32_VideoController) | ForEach-Object { $_.Name }) -join ', '
$hardware = [ordered]@{
    cpu = $cpu; ramGB = $ramGB; gpu = $gpus
}

# ---------- Инсталирани програми (без админ; подсказки в приложението) ----------
$progNames = @()
foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
    Get-ItemProperty $root -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.DisplayName) { $progNames += $_.DisplayName }
    }
}
$programs = @($progNames | Sort-Object -Unique)

# ---------- Администраторски секции ----------
$isAdmin = Test-Admin
$adminRequired = @()

if ($isAdmin) {
    # Опционални компоненти
    $feat = @{}
    $map = @{
        hyperV  = 'Microsoft-Hyper-V-All'
        wsl     = 'Microsoft-Windows-Subsystem-Linux'
        sandbox = 'Containers-DisposableClientVM'
        netFx3  = 'NetFx3'
    }
    foreach ($k in $map.Keys) {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $map[$k]
        $feat[$k] = ($f.State -eq 'Enabled')
    }

    # BitLocker (системен том)
    $bl = $null
    $blv = Get-BitLockerVolume -MountPoint $env:SystemDrive
    if ($blv) { $bl = @{ volumeStatus = [string]$blv.VolumeStatus; protectionStatus = [string]$blv.ProtectionStatus } }

    # Дискове и партиции
    $disks = @()
    Get-Disk | ForEach-Object {
        $d = $_
        $parts = Get-Partition -DiskNumber $d.Number | ForEach-Object {
            [ordered]@{ number = $_.PartitionNumber; driveLetter = "$($_.DriveLetter)"; sizeGB = [math]::Round($_.Size/1GB, 1); type = [string]$_.GptType }
        }
        $disks += [ordered]@{ number = $d.Number; friendlyName = $d.FriendlyName; sizeGB = [math]::Round($d.Size/1GB, 1); partitionStyle = [string]$d.PartitionStyle; busType = [string]$d.BusType; partitions = $parts }
    }
}
else {
    $adminRequired += 'features'
    $adminRequired += 'bitlocker'
    $adminRequired += 'disks'
    Write-Host 'Забележка: не сте администратор - секции "features", "bitlocker" и "disks" са пропуснати.' -ForegroundColor Yellow
    Write-Host 'Пуснете отново с "Като администратор", ако искате пълните данни.' -ForegroundColor Yellow
}

# ---------- Съпоставяне с winget каталога на WinSetup Studio ----------
$wingetMap = @{
    'Google.Chrome'                    = 'Google Chrome'
    'Mozilla.Firefox'                  = 'Mozilla Firefox'
    'Brave.Brave'                      = 'Brave'
    'Vivaldi.Vivaldi'                  = 'Vivaldi'
    '7zip.7zip'                        = '7-Zip'
    'voidtools.Everything'             = 'Everything'
    'AntibodySoftware.WizTree'         = 'WizTree'
    'Rufus.Rufus'                      = 'Rufus'
    'VideoLAN.VLC'                     = 'VLC media player'
    'IrfanView.IrfanView'              = 'IrfanView'
    'foobar2000.foobar2000'            = 'foobar2000'
    'Audacity.Audacity'                = 'Audacity'
    'OBSProject.OBSStudio'             = 'OBS Studio'
    'Notepad++.Notepad++'              = 'Notepad++'
    'LibreOffice.LibreOffice'          = 'LibreOffice'
    'SumatraPDF.SumatraPDF'            = 'SumatraPDF'
    'Adobe.Acrobat.Reader.64-bit'      = 'Adobe Acrobat'
    'KDE.Krita'                        = 'Krita'
    'Microsoft.PowerShell'             = 'PowerShell 7'
    'Microsoft.VisualStudioCode'       = 'Visual Studio Code'
    'Git.Git'                          = 'Git'
    'Python.Python.3.12'               = 'Python 3.12'
    'OpenJS.NodeJS.LTS'                = 'Node.js'
    'Docker.DockerDesktop'             = 'Docker Desktop'
    'Postman.Postman'                  = 'Postman'
    'WiresharkFoundation.Wireshark'    = 'Wireshark'
    'PuTTY.PuTTY'                      = 'PuTTY'
    'WinSCP.WinSCP'                    = 'WinSCP'
    'Insecure.Nmap'                    = 'Nmap'
    'famatech.AdvancedIPScanner'       = 'Advanced IP Scanner'
    'qBittorrent.qBittorrent'          = 'qBittorrent'
    'FileZilla.FileZilla'              = 'FileZilla'
    'ShareX.ShareX'                    = 'ShareX'
    'Microsoft.PowerToys'              = 'PowerToys'
    'Discord.Discord'                  = 'Discord'
    'TelegramMessenger.TelegramDesktop'= 'Telegram'
    'Zoom.Zoom'                        = 'Zoom'
    'SlackTechnologies.Slack'          = 'Slack'
    'Notion.Notion'                    = 'Notion'
    'TeamViewer.TeamViewer'            = 'TeamViewer'
    'AnyDesk.AnyDesk'                  = 'AnyDesk'
    'Valve.Steam'                      = 'Steam'
    'Spotify.Spotify'                  = 'Spotify'
}
$matchedApps = @()
foreach ($k in $wingetMap.Keys) {
    $needle = $wingetMap[$k]
    $hit = $programs | Where-Object { $_ -like "*$needle*" } | Select-Object -First 1
    if ($hit) { $matchedApps += $k }
}
$matchedApps = @($matchedApps | Sort-Object -Unique)

# ---------- Запис ----------
$result = [ordered]@{
    type        = 'winsetup-studio-profile'
    version     = 2
    generated   = (Get-Date -Format 'o')
    computer    = $computer
    hardware    = $hardware
    settings    = $settings
    programs    = $programs
    matchedApps = $matchedApps
}
if ($isAdmin) { $result.features = $feat; $result.bitlocker = $bl; $result.disks = $disks }
$result.adminRequired = $adminRequired

$json = ConvertTo-Json -InputObject $result -Depth 8
try {
    Set-Content -Path $OutPath -Value $json -Encoding UTF8 -ErrorAction Stop
} catch {
    Write-Host ('ГРЕШКА при запис на профила: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Готово! Профилът е записан в:' -ForegroundColor Green
Write-Host "  $OutPath" -ForegroundColor Green
Write-Host ''
Write-Host 'Следваща стъпка: отвори WinSetupStudio.html -> „Импорт профил" или провлачи файла върху него.'
Write-Host ("Резюме: $productName ($displayVer), $cpu, ${ramGB}GB RAM, $($programs.Count) програми")

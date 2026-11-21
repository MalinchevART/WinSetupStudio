# ============================================================
#  WinSetup Studio - Make-SetupUSB.ps1 (v2)
#  Подготвя ИНСТАЛАЦИОННА ФЛАШКА с вграден autounattend.xml.
#
#  Какво прави:
#    1. ИЗТРИВА избраната флашка и я форматира FAT32 (задължително
#       за UEFI boot; FAT32 = max 32GB том и max 4GB файл!)
#    2. Копира съдържанието на Windows ISO (или папка) на флашката
#    3. Ако sources\install.wim е ПОГЛЕМАЛНА ОТ 4GB -> разделя го на
#       install.swm (dism /Split-Image). Setup разчита .swm автоматично.
#       (Това е "компресията, която се чупеше".)
#    4. Слага autounattend.xml в ROOT на флашката.
#    5. Копира и самия WinSetup Studio инструмент на флашката
#       (програмата пътува с нея) - изключва се с -NoApp.
#
#  Употреба (PowerShell КАТО АДМИНИСТРАТОР):
#    # с изрична буква:
#    .\Make-SetupUSB.ps1 -IsoPath "C:\ISO\Win11.iso" -UsbDrive "E:"
#    # без буква -> сам изброява USB флашките и пита:
#    .\Make-SetupUSB.ps1 -IsoPath "C:\ISO\Win11.iso"
#    # разархивиран ISO вместо .iso файл:
#    .\Make-SetupUSB.ps1 -SourceDir "D:\Win11-ISO" -UsbDrive "E:"
#    Добавете -WhatIf, за да видите плана БЕЗ нищо да се изпълнява.
# ============================================================
[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Iso', Mandatory = $true)]
    [string]$IsoPath,

    [Parameter(ParameterSetName = 'Dir', Mandatory = $true)]
    [string]$SourceDir,

    [string]$UsbDrive,          # буква на флашката, напр. "E:" - ОПЦИОНАЛНО

    [string]$UnattendPath = "$PSScriptRoot\autounattend.xml",

    [switch]$NoApp,             # не копирай WinSetup Studio инструмента на флашката

    [switch]$Force,             # позволи и НЕ-USB диск (изричният избор е твой отговор)

    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Cmd([string]$cmd, [string]$okMsg) {
    Write-Host "  > $cmd" -ForegroundColor DarkGray
    Invoke-Expression $cmd
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Командата върна грешка ($LASTEXITCODE): $cmd" }
    if ($okMsg) { Write-Host "  OK: $okMsg" -ForegroundColor Green }
}
# (Assert-Cmd вече не се използва за dism — виж стъпка 3; оставен е за съвместимост.)

Write-Host '== WinSetup Studio: подготовка на инсталационна флашка ==' -ForegroundColor Cyan

if (-not (Test-Admin)) {
    throw 'Трябва да стартирате скрипта КАТО АДМИНИСТРАТОР (десен клик -> PowerShell (Admin)).'
}

# ---------- Валидация на източника ----------
if ($PSCmdlet.ParameterSetName -eq 'Iso') {
    if (-not (Test-Path $IsoPath)) { throw "Не намирам ISO: $IsoPath" }
} else {
    if (-not (Test-Path $SourceDir)) { throw "Не намирам папка: $SourceDir" }
}

if (-not (Test-Path $UnattendPath)) {
    Write-Host "ПРЕДУПРЕЖДЕНИЕ: не намирам $UnattendPath - ще продължа БЕЗ unattend файл." -ForegroundColor Yellow
    Write-Host '(Можете да копирате autounattend.xml на флашката и ръчно после.)' -ForegroundColor Yellow
}

# ---------- Избор на флашка ----------
$usbDisk = $null
if ($UsbDrive) {
    if (-not $UsbDrive.EndsWith(':')) { $UsbDrive = "$UsbDrive`:" }
    $UsbDrive = $UsbDrive.TrimEnd('\')
    $part = Get-Partition -DriveLetter $UsbDrive.TrimEnd(':') -ErrorAction SilentlyContinue
    if (-not $part) { throw "Не намирам дял с буква $UsbDrive. Проверете буквата на флашката (Get-Volume)." }
    $usbDisk = Get-Disk -Number $part.DiskNumber
    $usbSizeGB = [math]::Round($usbDisk.Size / 1GB, 1)
} else {
    # Интерактивен избор: изброявам USB дисковете
    $usbs = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' })
    if (-not $usbs.Count) { throw 'Не виждам USB дискове. Закачете флашката или подайте -UsbDrive "E:".' }
    Write-Host ''
    Write-Host 'Намерени USB дискове:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $usbs.Count; $i++) {
        $v = Get-Partition -DiskNumber $usbs[$i].Number -ErrorAction SilentlyContinue |
             Where-Object { $_.DriveLetter } | Select-Object -First 1
        $letter = if ($v) { "$($v.DriveLetter):" } else { '(без буква)' }
        Write-Host ('  [' + ($i + 1) + '] Диск #' + $usbs[$i].Number + '  ' + $usbs[$i].FriendlyName +
                    '  ' + [math]::Round($usbs[$i].Size / 1GB, 1) + ' GB  ' + $letter)
    }
    $pick = Read-Host 'Коя е флашката? (номер, празно = отказ)'
    if (-not $pick) { Write-Host 'Отказано.'; return }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $usbs.Count) {
        throw 'Невалиден номер.'
    }
    $usbDisk = $usbs[$idx - 1]
    $usbSizeGB = [math]::Round($usbDisk.Size / 1GB, 1)
}

Write-Host ''
Write-Host 'ЦЕЛ:      Диск #'$usbDisk.Number '-' $usbDisk.FriendlyName -ForegroundColor Yellow
# ВСИЧКИ деструктивни проверки са ПРЕДИ първото изтриване (fail fast):
if ($usbDisk.BusType -ne 'USB' -and -not $Force) {
    throw ('Избраният диск НЕ е USB (BusType=' + $usbDisk.BusType + '). Ако СИГУРНО искаш този диск - подай -Force.')
}
if ($usbDisk.IsBoot -or $usbDisk.IsSystem) {
    throw 'Избраният диск е BOOT/SYSTEM диск на Windows - ОТКАЗВАМ да го изтрия!'
}
if ($usbSizeGB -gt 32) {
    throw ('Флашката е по-голяма от 32GB - Windows не може да я форматира FAT32. ' +
           'Два варианта: (а) използвайте флашка до 32GB; (б) форматirайте NTFS и я подгответе ' +
           'с Rufus (опция UEFI:NTFS), после сложете autounattend.xml в root.')
}
Write-Host 'ГОЛЕМИНА на флашката:' $usbSizeGB 'GB'
Write-Host 'ВНИМАНИЕ: ВСИЧКО на флашката ще бъде ИЗТРИТО!' -ForegroundColor Red

if (-not $WhatIf) {
    $a = Read-Host 'Продължи? (напишете ДА)'
    if ($a -cne 'ДА') { Write-Host 'Отказано.'; return }
}

# ---------- План / изпълнение ----------
Write-Host ''
if ($WhatIf) { Write-Host 'WHATIF - нищо няма да се изпълни, само планът:' -ForegroundColor Magenta }

# 1. Форматиране
Write-Host '[1/6] Изчистване и форматиране на флашката...' -ForegroundColor Cyan
if (-not $WhatIf) {
    # повторна проверка на идентичността МИГ ПРЕДИ изтриването
    $re = Get-Disk -Number $usbDisk.Number
    if (-not $re -or $re.IsBoot -or $re.IsSystem) { throw 'Дискът се промени между избора и изтриването - СПИРАМ за безопасност.' }
    Clear-Disk -Number $usbDisk.Number -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $usbDisk.Number -PartitionStyle GPT
    $np = New-Partition -DiskNumber $usbDisk.Number -UseMaximumSize -AssignDriveLetter
    $np = Get-Partition -DiskNumber $usbDisk.Number | Where-Object { $_.PartitionNumber -eq $np.PartitionNumber }
    $nl = "$($np.DriveLetter):"
    Format-Volume -DriveLetter $np.DriveLetter -FileSystem FAT32 -NewFileSystemLabel 'WINSETUP' -Confirm:$false | Out-Null
    Write-Host '  Форматирана като FAT32 на ' $nl -ForegroundColor Green
} else {
    Write-Host '  WHATIF: Clear-Disk, Initialize-Disk GPT, New-Partition, Format-Volume FAT32'
}

# 2. Източник (+3. wim split в try/finally — ISO се демонтира ВИНАГИ, дори при грешка)
Write-Host '[2/6] Копиране на инсталационните файлове...' -ForegroundColor Cyan
$srcLetter = $null
try {
    if (-not $WhatIf) {
        if ($PSCmdlet.ParameterSetName -eq 'Iso') {
            $mdi = Mount-DiskImage -ImagePath $IsoPath -PassThru
            $srcLetter = ($mdi | Get-Volume).DriveLetter
            $src = "$srcLetter`:\"
        } else { $src = $SourceDir.TrimEnd('\') + '\' }
        Write-Host '  Източник: ' $src
        robocopy $src "$($np.DriveLetter):\" /E /NFL /NDL /NJH /NJS /R:2 /W:2 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw 'Robocopy върна грешка при копирането.' }
        Write-Host '  Копирането приключи.' -ForegroundColor Green
    } else {
        Write-Host '  WHATIF: Mount ISO / robocopy източник -> флашка'
    }

    # 3. install.wim > 4GB -> split
    Write-Host '[3/6] Проверка за файлове над 4GB (FAT32 лимит)...' -ForegroundColor Cyan
    if (-not $WhatIf) {
        $wim = "$($np.DriveLetter):\sources\install.wim"
        if (Test-Path $wim) {
            $gb = (Get-Item $wim).Length / 1GB
            if ($gb -ge 4) {
                Write-Host ("  install.wim е {0:N2} GB - разделям на install.swm..." -f $gb) -ForegroundColor Yellow
                # директно извикване (без Invoke-Expression) — безопасно при пътища със спейсове
                & dism /Split-Image /ImageFile:"$wim" /SWMFile:"$($np.DriveLetter):\sources\install.swm" /FileSize:3800 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "dism /Split-Image върна грешка ($LASTEXITCODE)" }
                Write-Host '  install.swm създаден (Setup го разчита автоматично).' -ForegroundColor Green
                Remove-Item $wim -Force
                Write-Host '  Оригиналният install.wim е премахнат от флашката.' -ForegroundColor Green
            } else {
                Write-Host ('  install.wim е {0:N2} GB - под лимита, не е нужно разделяне.' -f $gb) -ForegroundColor Green
            }
        } else {
            Write-Host '  Няма install.wim (вероятно install.esd - той е под 4GB). ОК.' -ForegroundColor Green
        }
    } else {
        Write-Host '  WHATIF: при install.wim >= 4GB -> dism /Split-Image /FileSize:3800'
    }
} finally {
    if ($srcLetter) { try { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } catch {} }
}

# 4. autounattend.xml в root (с UTF-8 BOM — Setup чете кириллицата reliably)
Write-Host '[4/6] Поставяне на autounattend.xml в root...' -ForegroundColor Cyan
if (-not $WhatIf -and (Test-Path $UnattendPath)) {
    $dst = "$($np.DriveLetter):\autounattend.xml"
    Copy-Item $UnattendPath $dst -Force
    try {
        $txt = [System.IO.File]::ReadAllText($dst, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($dst, $txt, (New-Object System.Text.UTF8Encoding $true))
        Write-Host '  Готово (UTF-8 с BOM): ' $dst -ForegroundColor Green
    } catch {
        Write-Host '  Копирано (без BOM нормализация): ' $dst -ForegroundColor Yellow
    }
}

# 5. Инструментът WinSetup Studio -> на флашката
Write-Host '[5/6] Копиране на WinSetup Studio инструмента...' -ForegroundColor Cyan
if (-not $NoApp) {
    if (-not $WhatIf) {
        $toolDir = "$($np.DriveLetter):\WinSetupStudio"
        New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
        $tools = 'WinSetupStudio.html', 'WinSetupStudio.cmd', 'WinSetupStudio-Server.ps1',
                 'Get-WindowsIso.ps1', 'Make-SetupUSB.ps1', 'Export-WinSettings.ps1', 'README.md'
        foreach ($t in $tools) {
            $p = Join-Path $PSScriptRoot $t
            if (Test-Path $p) { Copy-Item $p $toolDir -Force }
        }
        # профилни JSON файлове до скрипта, ако има
        Get-ChildItem $PSScriptRoot -Filter '*profile*.json' -ErrorAction SilentlyContinue |
            Copy-Item -Destination $toolDir -Force -ErrorAction SilentlyContinue
        Write-Host '  Инструментът е на флашката: ' "$toolDir" -ForegroundColor Green
        Write-Host '  (Отваряте го от всяка машина: двойный клик върху WinSetupStudio.html)' -ForegroundColor DarkGray
    } else {
        Write-Host '  WHATIF: копиране на WinSetupStudio.html/.cmd/.ps1 + README в \WinSetupStudio\'
    }
} else {
    Write-Host '  (-NoApp: пропускам копирането на инструмента)'
}

# 6. Крайни инструкции
Write-Host '[6/6] ГОТОВО!' -ForegroundColor Green
Write-Host ''
Write-Host 'Как да инсталирате:' -ForegroundColor Cyan
Write-Host '  1. Boot от флашката (UEFI). Инсталацията тече сама - без въпроси.'
Write-Host '  2. Ако 25H2/26H2 "ConX" режим игнорира файла: Shift+F10 в началото ->'
Write-Host '     setup.exe /Unattend:E:\autounattend.xml  (буквата на флашката може да е друга).'
Write-Host '  3. Ако пак поиска MS акаунт: изключете интернет кабела/Wi-Fi, или в CMD:'
Write-Host '     start ms-cxh:localonly'
Write-Host ''
Write-Host 'Бележка: файлът се чете от Setup САМО в root директорията на носителя.'

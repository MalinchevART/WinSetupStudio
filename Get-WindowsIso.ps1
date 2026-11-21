# ============================================================
#  WinSetup Studio - Get-WindowsIso.ps1
#  Взима ОФИЦИАЛНА директна връзка за Windows ISO от сървърите
#  на Microsoft (същият "software-download-connector" API, който
#  ползва страницата на Microsoft и скриптът Fido v1.72) и сваля
#  ISO-а. Не е пиратство - същите линкове дава microsoft.com.
#
#  Употреба:
#    # списък на наличните езици (без сваляне):
#    powershell -ExecutionPolicy Bypass -File Get-WindowsIso.ps1 -ListLangs
#
#    # директна връзка без сваляне (за проверка):
#    powershell -ExecutionPolicy Bypass -File Get-WindowsIso.ps1 -List
#
#    # пълно сваляне (5-6 GB, отнема време):
#    powershell -ExecutionPolicy Bypass -File Get-WindowsIso.ps1 `
#        -Version Win11 -Language Bulgarian `
#        -OutPath "$env:USERPROFILE\Downloads\Win11_26H2_bulgarian.iso"
# ============================================================
[CmdletBinding()]
param(
    [ValidateSet('Win11', 'Win10')]
    [string]$Version = 'Win11',

    [string]$Language = 'Bulgarian',   # име на езика; виж -ListLangs за точните имена

    [string]$OutPath = '',

    [switch]$List,        # показва директната връзка БЕЗ да сваля
    [switch]$ListLangs    # показва наличните езици за избраната версия
)

$ErrorActionPreference = 'Stop'
$DefaultTimeout = 40
# PS 5.1: гарантирай TLS 1.2 (без това старите .NET настройки чупят HTTPS) + без бавния progress render
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# productEditionId таблица (извлечена от Fido v1.72; Microsoft я сменя
# при нови версии - ако API-то откаже, линковете по-долу са резервният път)
$EDITION_IDS = @{
    Win11 = 3813    # Windows 11 26H2 Home/Pro/Edu (x64) - Build 26300, 2026.09
    Win10 = 2618    # Windows 10 22H2 Home/Pro/Edu (x64)
}
$PAGE = @{ Win11 = 'windows11'; Win10 = 'windows11' }  # referer сегмент

$OrgId      = 'y6jn8c31'
$ProfileId  = '606624d44113'
$InstanceId = '560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175'
$UA         = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36'

function Write-Step([string]$m) { Write-Host '==> ' $m -ForegroundColor Cyan }

# ---------- 1. Сесия: GUID + "избелване" през vlscppe и ov-df ----------
function New-ConnectorSession {
    $guid = [guid]::NewGuid().ToString()

    Write-Step 'Регистрирам сесията (vlscppe)...'
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec $DefaultTimeout -MaximumRedirection 0 `
            -UserAgent $UA `
            -Uri "https://vlscppe.microsoft.com/tags?org_id=$OrgId&session_id=$guid" | Out-Null
    } catch {
        Write-Host '  (предупреждение: vlscppe не отговори очаквано - продължавам)' -ForegroundColor Yellow
    }

    Write-Step 'Регистрирам сесията (ov-df)...'
    try {
        $mdt = Invoke-RestMethod -UseBasicParsing -TimeoutSec $DefaultTimeout -UserAgent $UA `
            -Uri "https://ov-df.microsoft.com/mdt.js?instanceId=$InstanceId&PageId=si&session_id=$guid"
        $w      = [regex]::Match($mdt, '[?&]w=([A-F0-9]+)').Groups[1].Value
        $rticks = [regex]::Match($mdt, 'rticks\=\"\+?(\d+)').Groups[1].Value
        if (-not $w -or -not $rticks) { throw 'не мога да извлека w/rticks от mdt.js' }
        $epoch = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
        Invoke-WebRequest -UseBasicParsing -TimeoutSec $DefaultTimeout -MaximumRedirection 0 `
            -UserAgent $UA `
            -Uri "https://ov-df.microsoft.com/?session_id=$guid&CustomerId=$InstanceId&PageId=si&w=$w&mdt=$epoch&rticks=$rticks" | Out-Null
    } catch {
        Write-Host '  (предупреждение: ov-df не отговори очаквано - продължавам)' -ForegroundColor Yellow
    }
    return $guid
}

# ---------- 2. SKU информация: езици ----------
function Get-Skus([string]$guid, [int]$editionId, [string]$refererSegment) {
    $url = "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition" +
           "?profile=$ProfileId&productEditionId=$editionId&SKU=undefined&friendlyFileName=undefined" +
           "&Locale=en-US&sessionID=$guid"
    $attempt = 0
    while ($true) {
        if ($attempt -ne 0) { Start-Sleep -Seconds 2 }
        $r = Invoke-RestMethod -UseBasicParsing -TimeoutSec $DefaultTimeout -Uri $url
        if ($null -eq $r) { if ($attempt++ -le 1) { continue }; throw 'Сървърът не върна данни за езиците.' }
        if ($r.Errors) {
            if ($r.Errors[0].Type -eq 9) {
                throw ('Microsoft ограничи сесията (код 715-123130). Изчакай няколко минути или ' +
                       'свали от официалната страница: https://www.microsoft.com/software-download/' + $refererSegment)
            }
            if ($attempt++ -le 1) { continue }
            throw ('Грешка от API: ' + $r.Errors[0].Value)
        }
        return $r.Skus
    }
}

# ---------- 3. Директна връзка за x64 ----------
function Get-IsoLink([string]$guid, [int]$skuId, [string]$refererSegment) {
    $url = "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku" +
           "?profile=$ProfileId&productEditionId=undefined&SKU=$skuId&friendlyFileName=undefined" +
           "&Locale=en-US&sessionID=$guid"
    # Referer е ЗАДЪЛЖИТЕЛЕН за тази заявка, иначе сървърът отказва
    $r = Invoke-RestMethod -UseBasicParsing -TimeoutSec $DefaultTimeout `
            -Headers @{ 'Referer' = "https://www.microsoft.com/software-download/$refererSegment" } -Uri $url
    if ($r.Errors) {
        if ($r.Errors[0].Type -eq 9) {
            throw ('Microsoft ограничи сесията (код 715-123130). Изчакай и пробвай отново, или ' +
                   'ползвай официалната страница: https://www.microsoft.com/software-download/' + $refererSegment)
        }
        throw ('Грешка от API: ' + $r.Errors[0].Value)
    }
    # Избор на x64: Доказано (11.2026) DownloadType кодовете НЕ са надеждни
    # (единствената опция за x64 идва с тип 2), затова гледаме X64 в URI/име,
    # после тип 1, и накрая fallback на първата опция.
    $opt = @($r.ProductDownloadOptions | Where-Object { ($_.Uri -match 'X64') -or ($_.Name -match 'X64') })
    if (-not $opt) { $opt = @($r.ProductDownloadOptions | Where-Object { [int]$_.DownloadType -eq 1 }) }
    if (-not $opt) { $opt = @($r.ProductDownloadOptions) }
    if (-not $opt.Count) { throw 'Не намерих x64 ISO връзка в отговора.' }
    return $opt[0].Uri
}

# ============================================================
try {
    $editionId = [int]$EDITION_IDS[$Version]
    $seg       = $PAGE[$Version]
    $guid      = New-ConnectorSession

    Write-Step "Вземам езиците за $Version (editionId $editionId)..."
    $skus = Get-Skus $guid $editionId $seg

    if ($ListLangs) {
        Write-Host ''
        Write-Host 'Налични езици (-Language приема част от това име):' -ForegroundColor Green
        $skus | ForEach-Object {
            $loc = if ($_.LocalizedLanguage) { '  [' + $_.LocalizedLanguage + ']' } else { '' }
            Write-Host ('  ' + $_.Language + $loc)
        }
        return
    }

    $sku = $skus | Where-Object { $_.Language -like "*$Language*" } | Select-Object -First 1
    if (-not $sku) {
        Write-Host 'Не намирам този език. Наличните имена:' -ForegroundColor Yellow
        $skus | ForEach-Object { Write-Host ('  ' + $_.Language) }
        throw "Езикът '$Language' не е наличен за $Version."
    }
    Write-Host ('  избран: ' + $sku.Language + ' (SKU ' + $sku.Id + ')') -ForegroundColor DarkGray

    Write-Step 'Вземам директната връзка (x64)...'
    # 2 опита с свежа сесия при транзиентна грешка
    $isoUrl = $null
    for ($att = 0; $att -lt 2 -and -not $isoUrl; $att++) {
        if ($att -ne 0) { Start-Sleep -Seconds 2; $guid = New-ConnectorSession }
        try { $isoUrl = Get-IsoLink $guid ([int]$sku.Id) $seg } catch { if ($att -eq 1) { throw } }
    }
    Write-Host ''
    Write-Host 'ОФИЦИАЛНА ВРЪЗКА ОТ MICROSOFT:' -ForegroundColor Green
    Write-Host $isoUrl
    Write-Host ''

    if ($List) { Write-Host '(-List: не свалям. Сложи връзката в браузър/IDM или пусни без -List.)' -ForegroundColor Yellow; return }

    if (-not $OutPath) {
        $lang = ($sku.Language -replace '[^\w]+', '_')
        $OutPath = "$env:USERPROFILE\Downloads\${Version}_$lang.iso"
    }
    $cl = (Invoke-WebRequest -UseBasicParsing -Method Head -TimeoutSec 60 -Uri $isoUrl).Headers['Content-Length']
    if ($cl) { Write-Host ('Свалям ' + [math]::Round($cl / 1GB, 2) + ' GB в: ' + $OutPath) }
    else { Write-Host ('Свалям в: ' + $OutPath) }

    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        Start-BitsTransfer -Source $isoUrl -Destination $OutPath -DisplayName 'WinSetup Studio: Windows ISO'
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri $isoUrl -OutFile $OutPath
    }
    Write-Host ''
    Write-Host 'ГОТОВО! ISO-ът е в: ' $OutPath -ForegroundColor Green
    Write-Host 'Следваща стъпка: Make-SetupUSB.ps1 -IsoPath (този път) -UsbDrive ...'
}
catch {
    Write-Host ''
    Write-Host ('ГРЕШКА: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    Write-Host 'Резервни (винаги работещи) варианти:' -ForegroundColor Yellow
    Write-Host '  Windows 11: https://www.microsoft.com/software-download/windows11'
    Write-Host '  Windows 10: https://www.microsoft.com/software-download/windows10'
    exit 1
}

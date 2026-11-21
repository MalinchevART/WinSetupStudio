# ============================================================
#  WinSetup Studio - WinSetupStudio-Server.ps1 (helper)
#  Локален помощник: HTTP сървър на 127.0.0.1, който позволява на
#  приложението да изпълнява операциите С ЕДИН КЛИК:
#    /api/ping   -> статус (админ?, версия)
#    /api/export -> прочитай настройките на този комп -> JSON отговор
#    /api/usb    -> стартира Make-SetupUSB.ps1 в видим прозорец
#    /api/iso    -> стартира Get-WindowsIso.ps1 в видим прозорец
#  Стартира се от WinSetupStudio.cmd (които сам се повишава към
#  администратор през UAC). Служи и HTML-а на приложението.
#
#  СИГУРНОСТ: заявки се приемат САМО от собственото UI (Host = loopback,
#  Origin = same-origin / null от file://). Чужди сайтове → 403.
# ============================================================
[CmdletBinding()]
param(
    [int]$Port = 8891,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$script:ACAO = $null

function Test-PortFree([int]$p) {
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
        $l.Start(); $l.Stop(); return $true
    } catch { return $false }
}
while (-not (Test-PortFree $Port) -and $Port -lt 8899) { $Port++ }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- Сигурност: само заявки от собственото UI ----------
# 1) Host задължително loopback (блокира DNS rebinding);
# 2) Origin: липсващ = same-origin GET; 'null' = file:// страница;
#    http://127.0.0.1:PORT / http://localhost:PORT = нашето UI. Всичко друго → reject.
function Test-RequestAllowed([System.Net.HttpListenerRequest]$req) {
    if ($req.Headers['Host'] -ne "127.0.0.1:$Port" -and $req.Headers['Host'] -ne "localhost:$Port") { return $false }
    $script:ACAO = $null
    $origin = $req.Headers['Origin']
    if ($null -eq $origin) { return $true }
    if ($origin -eq 'null') { $script:ACAO = 'null'; return $true }
    if ($origin.TrimEnd('/') -in @("http://127.0.0.1:$Port", "http://localhost:$Port")) { return $true }
    return $false
}

function Send-Json([System.Net.HttpListenerResponse]$res, [object]$obj, [int]$code = 200) {
    $json = $obj | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $res.StatusCode = $code
    $res.ContentType = 'application/json; charset=utf-8'
    if ($script:ACAO) { $res.Headers.Add('Access-Control-Allow-Origin', $script:ACAO) }
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Send-File([System.Net.HttpListenerResponse]$res, [string]$path, [string]$mime) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $res.StatusCode = 200
    $res.ContentType = $mime
    if ($script:ACAO) { $res.Headers.Add('Access-Control-Allow-Origin', $script:ACAO) }
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

$isAdmin = Test-Admin

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
} catch {
    Write-Host ('ГРЕШКА: не мога да отворя порт ' + $Port + ' — ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Пробвай друг порт: .\WinSetupStudio-Server.ps1 -Port 8895' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host '== WinSetup Studio helper ==' -ForegroundColor Cyan
Write-Host ('  Адрес:  http://127.0.0.1:' + $Port + '/')
Write-Host ('  Админ:  ' + $(if ($isAdmin) { 'ДА (операциите имат пълни права)' } else { 'НЕ — export е частичен; рестартирай WinSetupStudio.cmd и приеми UAC' }) ) -ForegroundColor $(if ($isAdmin) { 'Green' } else { 'Yellow' })
Write-Host '  Остави този прозорец отворен, докато ползваш приложението. Затвори с Ctrl+C или затваряне на прозореца.'

if (-not $NoBrowser) {
    Start-Sleep -Milliseconds 500
    $url = "http://127.0.0.1:$Port/WinSetupStudio.html"
    $edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (-not (Test-Path $edge)) { $edge = "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe" }
    if (Test-Path $edge) { Start-Process $edge -ArgumentList ('--app=' + $url) }
    else { Start-Process $url }
    Write-Host '  Приложението е отворено в браузъра.'
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $res = $ctx.Response
    try {
        $path = $ctx.Request.Url.AbsolutePath
        $script:ACAO = $null

        if (-not (Test-RequestAllowed $ctx.Request)) {
            Send-Json $res @{ error = 'Отказано: заявката не е от собственото UI на WinSetup Studio (само localhost).' } 403
        }
        elseif ($path -eq '/api/ping') {
            Send-Json $res @{ ok = $true; admin = $isAdmin; version = '1.1.0'; port = $Port }
        }
        elseif ($path -eq '/api/export') {
            # Четене на настройките: child процес (наследява правата на helper-а), с timeout
            $out = Join-Path $env:TEMP ("wss-export-" + [guid]::NewGuid().ToString('N') + ".json")
            $p = Start-Process powershell -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', (Join-Path $root 'Export-WinSettings.ps1'),
                    '-OutPath', $out) `
                -PassThru -WindowStyle Hidden
            if (-not $p.WaitForExit(120000)) {
                try { $p.Kill() } catch {}
                Send-Json $res @{ error = 'export не завърши за 2 минути (спрян).' } 500
            }
            elseif ((Test-Path $out) -and $p.ExitCode -eq 0) {
                $json = Get-Content $out -Raw -Encoding UTF8
                Remove-Item $out -Force -ErrorAction SilentlyContinue
                $res.StatusCode = 200
                $res.ContentType = 'application/json; charset=utf-8'
                if ($script:ACAO) { $res.Headers.Add('Access-Control-Allow-Origin', $script:ACAO) }
                $b = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentLength64 = $b.Length
                $res.OutputStream.Write($b, 0, $b.Length)
            }
            else {
                Send-Json $res @{ error = ('export не успя (exit ' + $p.ExitCode + ')') } 500
            }
        }
        elseif ($path -eq '/api/usb') {
            if ($ctx.Request.ContentLength64 -gt 65536) {
                Send-Json $res @{ error = 'Прекалено голямо тяло на заявката.' } 413
            }
            else {
                $body = (New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch {}
                if (-not $req) {
                    Send-Json $res @{ error = 'Невалиден JSON в заявката.' } 400
                }
                elseif (-not $req.isoPath -or ($req.isoPath -match '["'']') -or ($req.isoPath -notmatch '\.iso$') -or -not (Test-Path $req.isoPath)) {
                    Send-Json $res @{ error = 'Липсва/невалиден isoPath — трябва да сочи към СЪЩЕСТВУВАЩ .iso файл (напр. C:\ISO\Win11.iso).' } 400
                }
                elseif ($req.usbDrive -and ($req.usbDrive -notmatch '^[A-Za-z]:?$')) {
                    Send-Json $res @{ error = 'Невалидна буква на флашката (напр. E:).' } 400
                }
                else {
                    # Аргументите се подават като ЕДИН предварително цитирани низ —
                    # пътища със спейсове и кавички са неутрализирани от валидацията горе.
                    $sa = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Make-SetupUSB.ps1') + '" -IsoPath "' + $req.isoPath + '"'
                    if ($req.usbDrive) { $sa += (' -UsbDrive "' + $req.usbDrive + '"') }
                    if ($req.whatIf) { $sa += ' -WhatIf' }
                    Start-Process powershell -ArgumentList $sa
                    Send-Json $res @{ started = $true; note = 'Отвори се PowerShell прозорец — потвърди там (напиши ДА). Ако helper-ът не е админ, скриптът ще те подскаже.' }
                }
            }
        }
        elseif ($path -eq '/api/iso') {
            if ($ctx.Request.ContentLength64 -gt 65536) {
                Send-Json $res @{ error = 'Прекалено голямо тяло на заявката.' } 413
            }
            else {
                $body = (New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch {}
                if (-not $req) {
                    Send-Json $res @{ error = 'Невалиден JSON в заявката.' } 400
                }
                else {
                    $ver = if ($req.version -and $req.version -in @('Win11', 'Win10')) { $req.version } else { 'Win11' }
                    $lang = if ($req.language -and ($req.language -match '^[A-Za-z ()-]{1,60}$')) { $req.language } else { 'Bulgarian' }
                    Start-Process powershell -ArgumentList @(
                        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                        (Join-Path $root 'Get-WindowsIso.ps1'),
                        '-Version', $ver, '-Language', $lang)
                    Send-Json $res @{ started = $true; note = 'Свалянето стартира в PowerShell прозорец (~5-6 GB, отива в Downloads).' }
                }
            }
        }
        elseif ($path -eq '/WinSetupStudio.html') {
            Send-File $res (Join-Path $root 'WinSetupStudio.html') 'text/html; charset=utf-8'
        }
        elseif ($path -eq '/') {
            $res.StatusCode = 302
            $res.Headers.Add('Location', '/WinSetupStudio.html')
        }
        else {
            $res.StatusCode = 404
            $b = [System.Text.Encoding]::UTF8.GetBytes('not found')
            $res.ContentLength64 = $b.Length
            $res.OutputStream.Write($b, 0, $b.Length)
        }
    } catch {
        try { Send-Json $res @{ error = $_.Exception.Message } 500 } catch {}
    } finally {
        try { $res.Close() } catch {}
    }
}

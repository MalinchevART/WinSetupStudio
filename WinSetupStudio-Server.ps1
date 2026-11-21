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

# ---------- Removable guard: само USB флашки за дестинационни операции ----------
function Test-RemovableLetter([string]$letterNoColon) {
    $part = Get-Partition -DriveLetter $letterNoColon -ErrorAction SilentlyContinue
    if (-not $part) { return $false }
    $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
    if (-not $disk) { return $false }
    if ($disk.IsBoot -or $disk.IsSystem -or $disk.IsReadOnly) { return $false }
    return ($disk.BusType -eq 'USB')
}

# ---------- Сигурност: САМО заявки от собственото UI ----------
# 1) Host задължително loopback (блокира DNS rebinding);
# 2) Origin: задължително точно нашето http://127.0.0.1:PORT / localhost:PORT;
#    изключение: GET без Origin header (same-origin навигация). 'null'/чужди → reject
#    (sandboxed iframe с Origin:null = drive-by вектор — премахнато след ревю);
# 3) Токен: всички /api/* (освен ping) изискват X-WSS-Token, инжектиран в сервираното UI.
$script:Token = [guid]::NewGuid().ToString('N')
$script:Nonce = [guid]::NewGuid().ToString('N')
$script:LastOp = (Get-Date).AddDays(-1)

function Test-RequestAllowed([System.Net.HttpListenerRequest]$req) {
    if ($req.Headers['Host'] -ne "127.0.0.1:$Port" -and $req.Headers['Host'] -ne "localhost:$Port") { return $false }
    $origin = $req.Headers['Origin']
    if ($origin) {
        if ($origin.TrimEnd('/') -notin @("http://127.0.0.1:$Port", "http://localhost:$Port")) { return $false }
    }
    elseif ($req.HttpMethod -ne 'GET') { return $false }
    return $true
}

function Test-Token([System.Net.HttpListenerRequest]$req) {
    if ($req.Url.AbsolutePath -eq '/api/ping') { return $true }
    return ($req.Headers['X-WSS-Token'] -eq $script:Token)
}

function Send-Json([System.Net.HttpListenerResponse]$res, [object]$obj, [int]$code = 200) {
    $json = $obj | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $res.StatusCode = $code
    $res.ContentType = 'application/json; charset=utf-8'
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Send-File([System.Net.HttpListenerResponse]$res, [string]$path, [string]$mime) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $res.StatusCode = 200
    $res.ContentType = $mime
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

        if (-not (Test-RequestAllowed $ctx.Request)) {
            Send-Json $res @{ error = 'Отказано: заявката не е от собственото UI на WinSetup Studio (само localhost).' } 403
        }
        elseif ($path -like '/api/*' -and $path -ne '/api/ping' -and -not (Test-Token $ctx.Request)) {
            Send-Json $res @{ error = 'Отказано: невалиден сесионен токен (X-WSS-Token).' } 401
        }
        elseif ($path -in @('/api/export', '/api/usb', '/api/apply', '/api/drivers', '/api/usb/writeunattend', '/api/usb/mkdir', '/api/iso') -and ((Get-Date) - $script:LastOp).TotalSeconds -lt 10) {
            Send-Json $res @{ error = 'Изчакай ~10 секунди между операциите (анти-спам).' } 429
        }
        elseif ($path -eq '/api/ping') {
            Send-Json $res @{ ok = $true; admin = $isAdmin; version = '1.3.0'; port = $Port }
        }
        elseif ($path -eq '/api/export') {
            # Четене на настройките: child процес (наследява правата на helper-а), с timeout
            $script:LastOp = Get-Date
            $out = Join-Path $env:TEMP ("wss-export-" + [guid]::NewGuid().ToString('N') + ".json")
            $sa = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Export-WinSettings.ps1') + '" -OutPath "' + $out + '"'
            $p = Start-Process powershell -ArgumentList $sa -PassThru -WindowStyle Hidden
            if (-not $p.WaitForExit(120000)) {
                try { $p.Kill() } catch {}
                Send-Json $res @{ error = 'export не завърши за 2 минути (спрян).' } 500
            }
            elseif ((Test-Path $out) -and $p.ExitCode -eq 0) {
                $json = Get-Content $out -Raw -Encoding UTF8
                Remove-Item $out -Force -ErrorAction SilentlyContinue
                $res.StatusCode = 200
                $res.ContentType = 'application/json; charset=utf-8'
                $b = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentLength64 = $b.Length
                $res.OutputStream.Write($b, 0, $b.Length)
            }
            else {
                Send-Json $res @{ error = ('export не успя (exit ' + $p.ExitCode + ')') } 500
            }
        }
        elseif ($path -eq '/api/usb') { $script:LastOp = Get-Date
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
        elseif ($path -eq '/api/iso') { $script:LastOp = Get-Date
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
        elseif ($path -eq '/api/apply') { $script:LastOp = Get-Date
            # Клон "След инсталация": изпълнява генерирания твикс/приложения скрипт СЕГА
            if ($ctx.Request.ContentLength64 -gt 262144) {
                Send-Json $res @{ error = 'Скриптът е прекалено голям.' } 413
            }
            else {
                $body = (New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch {}
                if (-not $req -or -not $req.script -or $req.script.Length -lt 40 -or ($req.script -notmatch ('WSS-NONCE ' + $script:Nonce))) {
                    Send-Json $res @{ error = 'Липсва/невалиден скрипт (nonce не съвпада — обнови страницата от helper-а).' } 400
                }
                else {
                    $f = Join-Path $env:TEMP ('wss-apply-' + [guid]::NewGuid().ToString('N') + '.ps1')
                    [System.IO.File]::WriteAllText($f, $req.script, (New-Object System.Text.UTF8Encoding $true))
                    Start-Process powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $f + '"')
                    Send-Json $res @{ started = $true; note = 'Скриптът стартира в PowerShell прозорец — гледай изхода там (лог: %WINDIR%\Temp\WinSetupStudio.log).' }
                }
            }
        }
        elseif ($path -eq '/api/usb/list') {
            $usbs = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' } | ForEach-Object {
                $d = $_
                $part = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Select-Object -First 1
                @{ number = $d.Number; name = $d.FriendlyName; sizeGB = [math]::Round($d.Size / 1GB, 1); letter = $(if ($part) { "$($part.DriveLetter):" } else { $null }) }
            })
            Send-Json $res @{ usbs = $usbs }
        }
        elseif ($path -eq '/api/usb/writeunattend') { $script:LastOp = Get-Date
            if ($ctx.Request.ContentLength64 -gt 524288) {
                Send-Json $res @{ error = 'XML-ът е прекалено голям.' } 413
            }
            else {
                $body = (New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch {}
                $letter = ''
                if ($req) {
                    $letter = ('' + $req.driveLetter).ToUpper().TrimEnd(':')
                    if ($letter -notmatch '^[A-Z]$') { $letter = '' }
                }
                if (-not $req -or -not $letter) {
                    Send-Json $res @{ error = 'Невалидна буква на флашката (напр. E:).' } 400
                }
                elseif (-not $req.xml -or $req.xml.Length -lt 100 -or $req.xml -notmatch '<unattend') {
                    Send-Json $res @{ error = 'Липсва/невалиден XML (не прилича на autounattend).' } 400
                }
                elseif (-not (Test-RemovableLetter $letter)) {
                    Send-Json $res @{ error = 'Отказвам: целта НЕ е removable USB диск (само флашки за autounattend).' } 400
                }
                else {
                    $dst = $letter + ':\autounattend.xml'
                    [System.IO.File]::WriteAllText($dst, $req.xml, (New-Object System.Text.UTF8Encoding $true))
                    Send-Json $res @{ written = $true; path = $dst }
                }
            }
        }
        elseif ($path -eq '/api/usb/mkdir') { $script:LastOp = Get-Date
            $body = (New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
            $req = $null
            try { $req = $body | ConvertFrom-Json } catch {}
            $letter = ''
            $folder = 'drivers'
            if ($req) {
                $letter = ('' + $req.driveLetter).ToUpper().TrimEnd(':')
                if ($letter -notmatch '^[A-Z]$') { $letter = '' }
                if ($req.folder -and ($req.folder -match '^[\w \-]{1,40}$')) { $folder = $req.folder }
            }
            if (-not $letter) {
                Send-Json $res @{ error = 'Невалидна буква на флашката.' } 400
            }
            elseif (-not (Test-RemovableLetter $letter)) {
                Send-Json $res @{ error = 'Отказвам: целта НЕ е removable USB диск.' } 400
            }
            else {
                $dir = $letter + ':\' + $folder
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Send-Json $res @{ created = $true; path = $dir }
            }
        }
        elseif ($path -eq '/api/iso/latest') {
            $latest = Get-ChildItem "$env:USERPROFILE\Downloads" -Filter '*.iso' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            Send-Json $res @{ isoPath = $(if ($latest) { $latest.FullName } else { $null }) }
        }
        elseif ($path -eq '/api/drivers') { $script:LastOp = Get-Date
            if ($ctx.Request.ContentLength64 -gt 65536) {
                Send-Json $res @{ error = 'Прекалено голямо тяло на заявката.' } 413
            }
            else {
                $body = (New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch {}
                if (-not $req -or -not $req.url) {
                    Send-Json $res @{ error = 'Липсва url (директната връзка към драйвер пакета).' } 400
                }
                else {
                    # домейн allowlist: само официални вендор домейни
                    $u = $null
                    try { $u = [uri]$req.url } catch {}
                    if (-not $u -or $u.Scheme -ne 'https' -or ($u.Host -notmatch '\.(lenovo|dell|hp)\.com$' -and $u.Host -notmatch '^(lenovo|dell|hp)\.com$')) {
                        $hst = if ($u) { $u.Host } else { 'invalid' }
                        Send-Json $res @{ error = ('URL-ът трябва да е от официален вендор домейн (lenovo.com / dell.com / hp.com) — получих: ' + $hst) } 400
                    }
                    else {
                        # дестинация: САМО буква от UI → папката се строи на сървъра (без client path)
                        $drvDir = "$env:USERPROFILE\Downloads\WinSetupStudio-drivers"
                        if ($req.driveLetter) {
                            $dl = ('' + $req.driveLetter).ToUpper().TrimEnd(':')
                            if ($dl -notmatch '^[A-Z]$') {
                                Send-Json $res @{ error = 'Невалидна буква на флашката.' } 400
                            }
                            elseif (-not (Test-RemovableLetter $dl)) {
                                Send-Json $res @{ error = 'Дестинацията НЕ е removable USB диск — отказвам.' } 400
                            }
                            else { $drvDir = $dl + ':\WinSetupStudio-drivers' }
                        }
                        if ($drvDir) {
                            New-Item -ItemType Directory -Path $drvDir -Force | Out-Null
                            $fname = ($u.Segments[-1] -replace '[^\w.\-]', '_')
                            # URL предаваме чрез meta ФАЙЛ — нула инжекционна повърхност в command line
                            $meta = Join-Path $env:TEMP ('wss-dl-' + [guid]::NewGuid().ToString('N') + '.json')
                            @{ url = $req.url; dest = $drvDir; fname = $fname } | ConvertTo-Json -Compress | Set-Content -Path $meta -Encoding UTF8
                            $runner = Join-Path $env:TEMP ('wss-dl-' + [guid]::NewGuid().ToString('N') + '.ps1')
                            $runnerCode = @'
param([string]$MetaPath)
$ProgressPreference = 'SilentlyContinue'
$m = Get-Content $MetaPath -Raw | ConvertFrom-Json
try {
    Start-BitsTransfer -Source $m.url -Destination (Join-Path $m.dest $m.fname) -DisplayName 'WinSetup Studio: driver pack'
    Write-Host 'ГОТОВО' -ForegroundColor Green
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
}
Read-Host 'Enter за изход'
'@
                            [System.IO.File]::WriteAllText($runner, $runnerCode, (New-Object System.Text.UTF8Encoding $true))
                            Start-Process powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $runner + '" -MetaPath "' + $meta + '"')
                            Send-Json $res @{ started = $true; note = ('Сваля се в ' + $drvDir + ' — после копирай в \drivers на флашката.') }
                        }
                    }
                }
            }
        }
        elseif ($path -eq '/WinSetupStudio.html') {
            # сервираме HTML-а с ИНЖЕКТИРАН токен + nonce; защита от clickjacking/кеширане
            $htmlTxt = [System.IO.File]::ReadAllText((Join-Path $root 'WinSetupStudio.html'), [System.Text.Encoding]::UTF8)
            $htmlTxt = $htmlTxt.Replace('__WSS_TOKEN__', $script:Token).Replace('__WSS_NONCE__', $script:Nonce)
            $b = [System.Text.Encoding]::UTF8.GetBytes($htmlTxt)
            $res.StatusCode = 200
            $res.ContentType = 'text/html; charset=utf-8'
            $res.Headers.Add('X-Frame-Options', 'DENY')
            $res.Headers.Add('Content-Security-Policy', "frame-ancestors 'none'")
            $res.Headers.Add('Cache-Control', 'no-store')
            $res.ContentLength64 = $b.Length
            $res.OutputStream.Write($b, 0, $b.Length)
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

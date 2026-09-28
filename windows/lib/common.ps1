$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# PS 5.1 без этого не включает TLS 1.2, а GitHub без него не отвечает
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
    [Net.SecurityProtocolType]::Tls12

$HonWinDir = Split-Path $PSScriptRoot -Parent
$HonRepoDir = Split-Path $HonWinDir -Parent
$HonBundleDir = Join-Path $HonRepoDir 'bundle'
$HonDataDir = Join-Path $env:LOCALAPPDATA 'hon-ru'
# В папку русификатора может не быть права записи, свежий перевод лежит здесь
$HonUpdateDir = Join-Path $HonDataDir 'bundle'
$HonRawUrl = 'https://raw.githubusercontent.com/ddgryaz/hon-ru/master/'
$HonUpdatePage = 'https://github.com/ddgryaz/hon-ru#обновление'
$HonShortcutName = 'HoN (RU).lnk'
$HonTitle = 'hon-ru'

$HonStrBases = @('entities', 'interface', 'client_messages', 'game_messages', 'bot_messages')
# Движок запрашивает interface.str и сам подставляет суффикс локали
$HonStrSuffixes = @('_en.str', '.str')

# У релиза нет .sha256 для win64.zip, хеш посчитан по файлу с GitHub
$HonZstdUrl = 'https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-v1.5.7-win64.zip'
$HonZstdSha256 = 'ACB4E8111511749DC7A3EBEDCA9B04190E37A17AFEB73F55D4425DBF0B90FAD9'
$HonZstdInZip = 'zstd-v1.5.7-win64\zstd.exe'

# Переопределяются в windows\config.local.ps1
$HonGameDir = $null
$HonDocsDir = $null
$HonUseTar = $true
$local = Join-Path $HonWinDir 'config.local.ps1'
if (Test-Path -LiteralPath $local) { . $local }

$script:HonLogFile = $null

function Start-HonLog($name) {
    New-Item -ItemType Directory -Force -Path $HonDataDir | Out-Null
    $script:HonLogFile = Join-Path $HonDataDir $name
    Set-Content -LiteralPath $script:HonLogFile -Value '' -Encoding UTF8
}

function Write-HonLog($message) {
    $line = '{0:HH:mm:ss.fff} {1}' -f (Get-Date), $message
    Write-Host $line
    # Журнал может на миг занять антивирус: из-за строки в нём перевод не теряем
    if ($script:HonLogFile) {
        try {
            Add-Content -LiteralPath $script:HonLogFile -Value $line -Encoding UTF8
        } catch {
        }
    }
}

# Без TopMost окно теряется за лаунчером: консоль скрипта скрыта
function Show-HonMessage($text, $buttons = 'OK', $icon = 'Information') {
    Add-Type -AssemblyName System.Windows.Forms
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    try {
        return [System.Windows.Forms.MessageBox]::Show($owner, $text, $HonTitle, $buttons, $icon)
    } finally {
        $owner.Dispose()
    }
}

$script:HonProgress = $null

# Окно без кнопок, не ждёт ответа. Скачивание идёт в этом же потоке,
# поэтому окно перерисовывается только через DoEvents
function Show-HonProgress($text) {
    if (-not $script:HonProgress) {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $form = New-Object System.Windows.Forms.Form -Property @{
            Text = $HonTitle; TopMost = $true; ControlBox = $false
            FormBorderStyle = 'FixedDialog'; StartPosition = 'CenterScreen'
            ClientSize = New-Object System.Drawing.Size(360, 70)
        }
        $label = New-Object System.Windows.Forms.Label -Property @{
            Text = $text; Dock = 'Fill'; TextAlign = 'MiddleCenter'
        }
        $form.Controls.Add($label)
        $form.Show()
        $script:HonProgress = $form
    }
    $script:HonProgress.Controls[0].Text = $text
    [System.Windows.Forms.Application]::DoEvents()
}

function Close-HonProgress {
    if ($script:HonProgress) {
        $script:HonProgress.Close()
        $script:HonProgress.Dispose()
        $script:HonProgress = $null
    }
}

# Каталог Juvio пользователь выбирает при установке. Запись в реестре может
# устареть после переноса, поэтому проверяем всех кандидатов по очереди
function Get-HonJuvioRoots {
    foreach ($hive in 'HKCU:', 'HKLM:') {
        $key = "$hive\Software\Microsoft\Windows\CurrentVersion\Uninstall"
        foreach ($item in Get-ChildItem -Path $key -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty -Path $item.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -like 'Heroes of Newerth*' -and $p.InstallLocation) {
                $p.InstallLocation.TrimEnd('\')
            }
        }
    }
    $cmd = (Get-ItemProperty -Path 'HKCU:\Software\Classes\hon\shell\open\command' `
            -ErrorAction SilentlyContinue).'(default)'
    if ($cmd -match '"([^"]+\\juvio\.exe)"') {
        Split-Path (Split-Path $Matches[1] -Parent) -Parent
    }
    Join-Path $env:LOCALAPPDATA 'Juvio'
}

function Test-HonJuvioRoot($root) {
    return (Test-Path -LiteralPath (Join-Path $root 'heroes of newerth\resources0.jz')) -and
        (Test-Path -LiteralPath (Join-Path $root 'bin\juvio.exe'))
}

function Find-HonGame {
    if ($HonGameDir) {
        $game = $HonGameDir.TrimEnd('\')
        $root = Split-Path $game -Parent
    } else {
        $roots = @(Get-HonJuvioRoots | Select-Object -Unique)
        $root = $roots | Where-Object { Test-HonJuvioRoot $_ } | Select-Object -First 1
        if (-not $root) { $root = $roots[0] }
        $game = Join-Path $root 'heroes of newerth'
    }
    $docs = $HonDocsDir
    if (-not $docs) {
        # Не USERPROFILE\Documents: папку переносят в OneDrive и на другие диски
        $docs = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Juvio\Heroes of Newerth'
    }
    $info = [pscustomobject]@{
        Root    = $root
        Game    = $game
        Archive = Join-Path $game 'resources0.jz'
        Exe     = Join-Path $root 'bin\juvio.exe'
        Logs    = Join-Path $root 'logs'
        Docs    = $docs
        Target  = Join-Path $game 'stringtables'
    }
    if (-not (Test-Path -LiteralPath $info.Archive) -or -not (Test-Path -LiteralPath $info.Exe)) {
        throw "Игра не найдена в папке $($info.Game)"
    }
    return $info
}

# Путь, где искали, только в журнал: в окне он пользователю не поможет
function Show-HonGameNotFound($reason, $retry) {
    Write-HonLog "$reason"
    Show-HonMessage ("Игра не найдена.`n`n" +
        "Установите Heroes of Newerth через лаунчер Juvio, дождитесь окончания " +
        "загрузки и $retry ещё раз.") 'OK' 'Error' | Out-Null
}

function Test-HonRunning {
    return [bool](Get-Process -Name 'juvio' -ErrorAction SilentlyContinue)
}

# Лишний файл в каталоге игры - и лаунчер требует обновление. Чужое не трогаем.
# Сразу после выхода из игры файл может держать антивирус: повторяем, а сбой
# с одним файлом не должен оставить на месте остальные
function Remove-HonFiles($game) {
    $removed = 0
    foreach ($base in $HonStrBases) {
        foreach ($suffix in $HonStrSuffixes) {
            $path = Join-Path $game.Target ($base + $suffix)
            for ($try = 1; (Test-Path -LiteralPath $path) -and $try -le 10; $try++) {
                try {
                    Remove-Item -LiteralPath $path -Force
                    $removed++
                } catch {
                    if ($try -eq 10) { Write-HonLog "не удалось удалить $path : $_" }
                    Start-Sleep -Milliseconds 300
                }
            }
        }
    }
    try {
        if ((Test-Path -LiteralPath $game.Target) -and
            -not (Get-ChildItem -LiteralPath $game.Target -Force)) {
            Remove-Item -LiteralPath $game.Target -Force
        }
    } catch {
        Write-HonLog "не удалось удалить $($game.Target) : $_"
    }
    return $removed
}

# PS 5.1 при Stop превращает любой stderr (даже с 2>$null) в исключение,
# а нам нужен код возврата
function Invoke-HonNative($exe, [string[]]$arguments) {
    $ErrorActionPreference = 'Continue'
    & $exe @arguments 2>$null | Out-Null
    return $LASTEXITCODE
}

function Get-HonTar {
    if (-not $HonUseTar) { return $null }
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) { return $null }
    $ErrorActionPreference = 'Continue'
    $version = (& $tar --version 2>$null) | Out-String
    # tar из Windows 10 собран без zstd
    if ($version -match 'libzstd') { return $tar }
    return $null
}

function Test-HonZstd($path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }
    $ErrorActionPreference = 'Continue'
    $version = (& $path --version 2>$null) | Out-String
    return $version -match 'Zstandard'
}

function Find-HonZstd {
    $candidates = @(
        (Join-Path $HonWinDir 'zstd.exe'),
        (Join-Path $HonDataDir 'zstd.exe')
    )
    $inPath = Get-Command -Name 'zstd.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($inPath) { $candidates += $inPath.Source }
    foreach ($programs in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if (-not $programs) { continue }
        $candidates += Join-Path $programs 'Git\usr\bin\zstd.exe'
        $candidates += Join-Path $programs 'Git\mingw64\bin\zstd.exe'
    }
    foreach ($candidate in $candidates) {
        if (Test-HonZstd $candidate) { return $candidate }
    }
    return $null
}

function Get-HonZstdDownload {
    $zip = Join-Path $env:TEMP ('hon-ru-zstd-' + [guid]::NewGuid() + '.zip')
    $unpack = $zip + '.d'
    try {
        Write-HonLog "скачиваю $HonZstdUrl"
        Invoke-WebRequest -Uri $HonZstdUrl -OutFile $zip -UseBasicParsing -TimeoutSec 60
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($hash -ne $HonZstdSha256) {
            throw "контрольная сумма не совпала: $hash"
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
        New-Item -ItemType Directory -Force -Path $HonDataDir | Out-Null
        $dst = Join-Path $HonDataDir 'zstd.exe'
        Copy-Item -LiteralPath (Join-Path $unpack $HonZstdInZip) -Destination $dst -Force
        if (-not (Test-HonZstd $dst)) {
            throw 'скачанный zstd.exe не запускается'
        }
        return $dst
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $unpack -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# $null - распаковщика нет; выбор пользователя в $script:HonUnpackerChoice:
# 'manual' (пошёл скачивать сам) или 'english'
function Resolve-HonUnpacker {
    $script:HonUnpackerChoice = $null
    $tar = Get-HonTar
    if ($tar) { return @{ Kind = 'tar'; Path = $tar } }
    $zstd = Find-HonZstd
    if ($zstd) { return @{ Kind = 'zstd'; Path = $zstd } }
    try {
        return @{ Kind = 'zstd'; Path = (Get-HonZstdDownload) }
    } catch {
        Write-HonLog "не удалось скачать zstd.exe: $_"
    }

    $text = "Не удалось скачать zstd.exe, без него перевод не подключить.`n`n" +
        "1. Скачайте архив:`n$HonZstdUrl`n" +
        "2. Скопируйте из него zstd.exe в папку:`n$HonWinDir`n" +
        "3. Запустите ярлык `"HoN (RU)`" ещё раз.`n`n" +
        "Да - открыть ссылку и папку.`nНет - играть на английском."
    $answer = Show-HonMessage $text 'YesNo' 'Warning'
    if ($answer -eq 'Yes') {
        Start-Process $HonZstdUrl
        Start-Process explorer.exe -ArgumentList "`"$HonWinDir`""
        $script:HonUnpackerChoice = 'manual'
    } else {
        $script:HonUnpackerChoice = 'english'
    }
    return $null
}

function Get-HonZipEntries($archive, $pattern) {
    $fs = [IO.File]::OpenRead($archive)
    $br = New-Object IO.BinaryReader($fs)
    try {
        $tailLength = [int][Math]::Min([int64]70000, $fs.Length)
        $fs.Position = $fs.Length - $tailLength
        $tail = $br.ReadBytes($tailLength)
        $eocd = -1
        for ($i = $tail.Length - 22; $i -ge 0; $i--) {
            if ([BitConverter]::ToUInt32($tail, $i) -eq 0x06054b50) { $eocd = $i; break }
        }
        if ($eocd -lt 0) { throw 'в resources0.jz не найдено оглавление zip' }
        $cdSize = [uint64][BitConverter]::ToUInt32($tail, $eocd + 12)
        $cdOffset = [uint64][BitConverter]::ToUInt32($tail, $eocd + 16)
        # Архив больше 4 ГБ: настоящее оглавление в ZIP64
        if ($eocd -ge 20 -and [BitConverter]::ToUInt32($tail, $eocd - 20) -eq 0x07064b50) {
            $fs.Position = [BitConverter]::ToUInt64($tail, $eocd - 20 + 8)
            if ($br.ReadUInt32() -ne 0x06064b50) { throw 'в resources0.jz битое оглавление ZIP64' }
            $z64 = $br.ReadBytes(52)
            $cdSize = [BitConverter]::ToUInt64($z64, 36)
            $cdOffset = [BitConverter]::ToUInt64($z64, 44)
        }
        $fs.Position = $cdOffset
        $cd = $br.ReadBytes([int]$cdSize)
    } finally {
        $br.Close()
    }

    # Литерал 0xFFFFFFFF в PowerShell равен -1
    $max32 = [uint32]::MaxValue
    $entries = @()
    $p = 0
    while ($p + 46 -le $cd.Length -and [BitConverter]::ToUInt32($cd, $p) -eq 0x02014b50) {
        $method = [BitConverter]::ToUInt16($cd, $p + 10)
        $csize = [uint64][BitConverter]::ToUInt32($cd, $p + 20)
        $usize = [uint64][BitConverter]::ToUInt32($cd, $p + 24)
        $nameLength = [BitConverter]::ToUInt16($cd, $p + 28)
        $extraLength = [BitConverter]::ToUInt16($cd, $p + 30)
        $commentLength = [BitConverter]::ToUInt16($cd, $p + 32)
        $offset = [uint64][BitConverter]::ToUInt32($cd, $p + 42)
        $name = [Text.Encoding]::UTF8.GetString($cd, $p + 46, $nameLength)
        if ($name -match $pattern) {
            # В extra только поля, равные 0xFFFFFFFF в заголовке, строго в этом порядке
            $e = $p + 46 + $nameLength
            $end = $e + $extraLength
            while ($e + 4 -le $end) {
                $id = [BitConverter]::ToUInt16($cd, $e)
                $size = [BitConverter]::ToUInt16($cd, $e + 2)
                if ($id -eq 1) {
                    $q = $e + 4
                    if ($usize -eq $max32) { $usize = [BitConverter]::ToUInt64($cd, $q); $q += 8 }
                    if ($csize -eq $max32) { $csize = [BitConverter]::ToUInt64($cd, $q); $q += 8 }
                    if ($offset -eq $max32) { $offset = [BitConverter]::ToUInt64($cd, $q); $q += 8 }
                }
                $e += 4 + $size
            }
            $entries += [pscustomobject]@{
                Name = $name; Method = $method; CSize = $csize; USize = $usize; Offset = $offset
            }
        }
        $p += 46 + $nameLength + $extraLength + $commentLength
    }
    return $entries
}

function Expand-HonWithZstd($archive, $zstd, $names, $dst) {
    $wanted = '^stringtables/(' + (($names | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
    $entries = Get-HonZipEntries $archive $wanted
    $fs = [IO.File]::OpenRead($archive)
    $br = New-Object IO.BinaryReader($fs)
    try {
        foreach ($entry in $entries) {
            $fs.Position = $entry.Offset
            $local = $br.ReadBytes(30)
            if ([BitConverter]::ToUInt32($local, 0) -ne 0x04034b50) {
                throw "битый заголовок $($entry.Name) в resources0.jz"
            }
            $fs.Position = $entry.Offset + 30 + [BitConverter]::ToUInt16($local, 26) +
                [BitConverter]::ToUInt16($local, 28)
            $data = $br.ReadBytes([int]$entry.CSize)
            $out = Join-Path $dst (Split-Path $entry.Name -Leaf)
            if ($entry.Method -eq 0) {
                [IO.File]::WriteAllBytes($out, $data)
            } elseif ($entry.Method -eq 93) {
                $packed = $out + '.zst'
                [IO.File]::WriteAllBytes($packed, $data)
                $code = Invoke-HonNative $zstd @('-d', '-q', '-f', $packed, '-o', $out)
                if ($code -ne 0) { throw "zstd не распаковал $($entry.Name): код $code" }
                Remove-Item -LiteralPath $packed -Force
            } else {
                throw "неизвестный метод сжатия $($entry.Method) у $($entry.Name)"
            }
        }
    } finally {
        $br.Close()
    }
}

# База обязательна: файл на диске подменяет архивный целиком, отката по ключам нет
function Expand-HonBase($game, $unpacker, $dst) {
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $names = $HonStrBases | ForEach-Object { $_ + '_en.str' }
    if ($unpacker.Kind -eq 'tar') {
        $members = $names | ForEach-Object { 'stringtables/' + $_ }
        $code = Invoke-HonNative $unpacker.Path (@('-xf', $game.Archive, '-C', $dst) + $members)
        # Ненулевой код бывает и когда патч убрал один из файлов. Но tar без
        # zstd может оставить пустые файлы - такие за успех не считаем
        $got = @(Get-ChildItem -LiteralPath (Join-Path $dst 'stringtables') -ErrorAction SilentlyContinue)
        $whole = $got.Count -gt 0 -and -not ($got | Where-Object { $_.Length -eq 0 })
        if ($whole -and ($code -eq 0 -or $got.Count -lt $names.Count)) {
            $got | Move-Item -Destination $dst
            return
        }
        # libzstd в tar ещё не значит, что он читает zstd внутри zip
        Write-HonLog "tar не справился (код $code), пробую zstd.exe"
        $zstd = Find-HonZstd
        if (-not $zstd) { $zstd = Get-HonZstdDownload }
        $unpacker = @{ Kind = 'zstd'; Path = $zstd }
    }
    Expand-HonWithZstd $game.Archive $unpacker.Path $names $dst
    if (-not (Get-ChildItem -LiteralPath $dst -Filter '*_en.str')) {
        throw 'в resources0.jz нет строк игры'
    }
}

$script:Utf8 = New-Object Text.UTF8Encoding($false)

# Сложение массивов в PowerShell даёт object[] и на мегабайтах тормозит
function Join-HonBytes([byte[]]$head, [int]$count, [byte[]]$body) {
    $ms = New-Object IO.MemoryStream
    $ms.Write($head, 0, $count)
    $ms.Write($body, 0, $body.Length)
    return ,$ms.ToArray()
}

function Test-HonUtf8Bom([byte[]]$data) {
    return $data.Length -ge 3 -and $data[0] -eq 0xEF -and $data[1] -eq 0xBB -and $data[2] -eq 0xBF
}

# Повторяет parse_str из tools/strfile.py: сборки обязаны совпадать побайтно.
# Около 300 строк в игре разделены пробелами, а не табом; таб проверяется
# первым, потому что в ключе бывает пробел (`Extra tooltip?`)
function Read-HonStr([byte[]]$data) {
    $skip = 0
    if (Test-HonUtf8Bom $data) { $skip = 3 }
    $text = $script:Utf8.GetString($data, $skip, $data.Length - $skip)
    $order = New-Object 'System.Collections.Generic.List[string]'
    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($line in $text.Replace("`r`n", "`n").Split("`n")) {
        if ($line.Length -eq 0 -or $line.StartsWith('//')) { continue }
        $tab = $line.IndexOf("`t")
        if ($tab -ge 0) {
            $key = $line.Substring(0, $tab)
            $value = $line.Substring($tab + 1)
        } else {
            $m = [regex]::Match($line, '(?s)^\s*(\S+)\s+(\S.*)$')
            if (-not $m.Success) { continue }
            $key = $m.Groups[1].Value
            $value = $m.Groups[2].Value
        }
        $key = $key.Trim()
        if (-not $map.ContainsKey($key)) { $order.Add($key) }
        $map[$key] = $value.Trim()
    }
    return [pscustomobject]@{ Order = $order; Map = $map }
}

# Timeout у HttpWebRequest не касается DNS, а тот без ответа висит ~15 с
function Test-HonOnline {
    try {
        $dns = [Net.Dns]::BeginGetHostAddresses(([Uri]$HonRawUrl).Host, $null, $null)
        if (-not $dns.AsyncWaitHandle.WaitOne(3000)) { throw 'DNS не ответил' }
        [void][Net.Dns]::EndGetHostAddresses($dns)
        return $true
    } catch {
        Write-HonLog "сети нет, обновления не проверяю: $_"
        return $false
    }
}

# PowerShell заворачивает WebException в MethodInvocationException.
# Ответ из исключения закрываем при любом коде: иначе соединение не вернётся
# в пул, а их всего два на сервер, и следующие запросы встанут в очередь
function Get-HonWebError($err, [Net.HttpStatusCode]$status) {
    $ex = $err.Exception
    while ($ex -and $ex -isnot [Net.WebException]) { $ex = $ex.InnerException }
    if (-not $ex -or -not $ex.Response) { return $false }
    $code = $ex.Response.StatusCode
    $ex.Response.Close()
    return $code -eq $status
}

# $null - не изменился (304). GitHub в РФ бывает медленным: тело читаем
# кусками до общего срока
function Invoke-HonGet($url, $etag, [DateTime]$deadline, $progress = $null) {
    $left = [int]($deadline - (Get-Date)).TotalMilliseconds
    if ($left -le 0) { throw 'не уложились по времени' }
    $request = [Net.HttpWebRequest]::Create($url)
    # Зависшее чтение не должно держать окно "Не отвечает" до конца срока
    $request.ReadWriteTimeout = [Math]::Min($left, 15000)
    # Распаковываем сами: длину можно сверить только до распаковки
    $request.Headers['Accept-Encoding'] = 'gzip'
    if ($etag) { $request.Headers['If-None-Match'] = $etag }
    # Ждём ответа сами, а не через Timeout: так можно показать окно, если
    # ответ задерживается. Недоступный GitHub не должен съедать весь срок,
    # но через DPI провайдера ответ бывает долгим
    $started = Get-Date
    $async = $request.BeginGetResponse($null, $null)
    while (-not $async.AsyncWaitHandle.WaitOne(100)) {
        $waited = ((Get-Date) - $started).TotalMilliseconds
        if ($waited -gt [Math]::Min($left, 15000)) {
            $request.Abort()
            # Отдельный тип: по нему apply.ps1 не ждёт GitHub второй раз
            throw [TimeoutException]'сервер не ответил'
        }
        if ($waited -gt 2000) { Show-HonProgress 'Проверяю обновления...' }
    }
    try {
        $response = $request.EndGetResponse($async)
    } catch {
        if (Get-HonWebError $_ NotModified) { return $null }
        throw
    }
    try {
        $ms = New-Object IO.MemoryStream
        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 65536
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $ms.Write($buffer, 0, $read)
            if ($progress) { Show-HonProgress $progress }
            if ((Get-Date) -gt $deadline) { throw 'не уложились по времени' }
        }
        $body = $ms.ToArray()
        # Оборванное соединение .NET не считает ошибкой
        if ($response.ContentLength -ge 0 -and $body.Length -ne $response.ContentLength) {
            throw "$url пришёл не целиком"
        }
        if ($response.ContentEncoding -eq 'gzip') {
            $gz = New-Object IO.Compression.GZipStream([IO.MemoryStream]::new($body), [IO.Compression.CompressionMode]::Decompress)
            $plain = New-Object IO.MemoryStream
            try { $gz.CopyTo($plain) } finally { $gz.Close() }
            $body = $plain.ToArray()
        }
        return [pscustomobject]@{ Bytes = $body; ETag = $response.Headers['ETag'] }
    } finally {
        $response.Close()
    }
}

# Копия меняется только целиком: смесь файлов разных версий не нужна.
# Без сети первый же запрос падает по таймауту, остальные не ждём
function Update-HonBundle([int]$seconds = 300) {
    $deadline = (Get-Date).AddSeconds($seconds)
    $progress = "Скачиваю обновление перевода.`nИгра запустится автоматически."
    $etagFile = Join-Path $HonUpdateDir 'etag.txt'
    $etags = @{}
    if (Test-Path -LiteralPath $etagFile) {
        foreach ($row in [IO.File]::ReadAllLines($etagFile)) {
            $name, $tag = $row.Split("`t", 2)
            if ($tag) { $etags[$name] = $tag }
        }
    }

    $got = @{}
    foreach ($base in $HonStrBases) {
        $name = $base + '_en.str'
        $etag = if (Test-Path -LiteralPath (Join-Path $HonUpdateDir $name)) { $etags[$name] } else { $null }
        $reply = Invoke-HonGet ($HonRawUrl + 'bundle/' + $name) $etag $deadline $progress
        if ($reply) { $got[$name] = $reply }
    }
    if (-not $got.Count) { return 'без изменений' }

    # Обрезанный файл или страница-заглушка провайдера не должны заменить перевод
    foreach ($name in $got.Keys) {
        $count = (Read-HonStr $got[$name].Bytes).Order.Count
        $shipped = Join-Path $HonBundleDir $name
        $floor = 1
        if (Test-Path -LiteralPath $shipped) {
            $floor = (Read-HonStr ([IO.File]::ReadAllBytes($shipped))).Order.Count / 2
        }
        if ($count -lt $floor) { throw "в скачанном $name всего $count строк" }
    }

    $next = $HonUpdateDir + '.new'
    if (Test-Path -LiteralPath $next) { Remove-Item -LiteralPath $next -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $next | Out-Null
    $rows = @()
    foreach ($base in $HonStrBases) {
        $name = $base + '_en.str'
        $path = Join-Path $next $name
        if ($got.ContainsKey($name)) {
            [IO.File]::WriteAllBytes($path, $got[$name].Bytes)
            $tag = $got[$name].ETag
        } else {
            Copy-Item -LiteralPath (Join-Path $HonUpdateDir $name) -Destination $path
            $tag = $etags[$name]
        }
        if ($tag) { $rows += "$name`t$tag" }
    }
    [IO.File]::WriteAllLines((Join-Path $next 'etag.txt'), [string[]]$rows)
    # Move-Item в существующую папку кладёт внутрь неё. Старую копию убираем
    # последней: папку с новыми файлами может держать антивирус
    $old = $HonUpdateDir + '.old'
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
    if (Test-Path -LiteralPath $HonUpdateDir) { Move-Item -LiteralPath $HonUpdateDir -Destination $old }
    try {
        Move-Item -LiteralPath $next -Destination $HonUpdateDir
    } catch {
        if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old -Destination $HonUpdateDir }
        throw
    }
    Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
    return 'скачано: ' + (($got.Keys | Sort-Object) -join ', ')
}

function Get-HonBundleDir {
    foreach ($base in $HonStrBases) {
        if (-not (Test-Path -LiteralPath (Join-Path $HonUpdateDir ($base + '_en.str')))) { return $HonBundleDir }
    }
    return $HonUpdateDir
}

function Get-HonScriptText([byte[]]$data) {
    # Git хранит LF, а в zip у игрока CRLF
    return $script:Utf8.GetString($data).Replace("`r", '')
}

function Get-HonHash([string]$text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    return [BitConverter]::ToString($sha.ComputeHash($script:Utf8.GetBytes($text))).Replace('-', '')
}

# Новый или удалённый в репозитории файл не в счёт: без правки остальных его
# никто не вызовет, а удалённый остаётся у игрока после распаковки поверх.
# Строка состояния: файл, хеш своей копии, ETag, совпадает ли
function Get-HonChangedScripts([int]$seconds = 60) {
    $deadline = (Get-Date).AddSeconds($seconds)
    $stateFile = Join-Path $HonDataDir 'scripts.txt'
    $state = @{}
    if (Test-Path -LiteralPath $stateFile) {
        foreach ($row in [IO.File]::ReadAllLines($stateFile)) {
            $path, $hash, $tag, $same = $row.Split("`t")
            $state[$path] = [pscustomobject]@{ Hash = $hash; ETag = $tag; Same = $same }
        }
    }

    $files = @(Get-ChildItem -LiteralPath $HonWinDir -Filter '*.bat' -File) +
        @(Get-ChildItem -LiteralPath (Join-Path $HonWinDir 'lib') -Filter '*.ps1' -File)
    $rows = @()
    $changed = @()
    foreach ($file in $files) {
        $rel = if ($file.Extension -eq '.bat') { 'windows/' + $file.Name } else { 'windows/lib/' + $file.Name }
        $mine = Get-HonScriptText ([IO.File]::ReadAllBytes($file.FullName))
        $hash = Get-HonHash $mine
        # Архив распаковали поверх без install.bat: прежний ответ уже не про эту копию
        $known = $state[$rel]
        if ($known -and $known.Hash -ne $hash) { $known = $null }
        try {
            $reply = Invoke-HonGet ($HonRawUrl + $rel) $(if ($known) { $known.ETag }) $deadline
        } catch {
            if (-not (Get-HonWebError $_ NotFound)) { throw }
            continue
        }
        if ($reply) {
            $same = if ((Get-HonScriptText $reply.Bytes) -eq $mine) { 'yes' } else { 'no' }
            $known = [pscustomobject]@{ Hash = $hash; ETag = $reply.ETag; Same = $same }
        }
        $rows += "$rel`t$hash`t$($known.ETag)`t$($known.Same)"
        if ($known.Same -ne 'yes') { $changed += "$rel`t$($known.ETag)" }
    }
    New-Item -ItemType Directory -Force -Path $HonDataDir | Out-Null
    [IO.File]::WriteAllLines($stateFile, [string[]]$rows)
    return ,$changed
}

# Про одну и ту же версию спрашиваем один раз, какой бы ни был ответ.
# Ответ в $script:HonScriptsChoice: 'update' - игрок пошёл обновляться
function Invoke-HonScriptsCheck {
    $script:HonScriptsChoice = $null
    try {
        $changed = Get-HonChangedScripts
    } finally {
        Close-HonProgress
    }
    if (-not $changed.Count) { return 'совпадают с master' }
    $names = ($changed | ForEach-Object { $_.Split("`t")[0] }) -join ', '
    $mark = Get-HonHash ($changed -join "`n")
    $seenFile = Join-Path $HonDataDir 'scripts.seen'
    if ((Test-Path -LiteralPath $seenFile) -and ([IO.File]::ReadAllText($seenFile).Trim() -eq $mark)) {
        return "отличаются ($names), игрок уже знает"
    }
    $answer = Show-HonMessage ("Вышла новая версия русификатора.`n`n" +
        "Да - открыть инструкцию по обновлению.`nНет - играть на текущей версии русификатора.") 'YesNo' 'Information'
    if ($answer -eq 'Yes') {
        Start-Process $HonUpdatePage
        $script:HonScriptsChoice = 'update'
    }
    # После Start-Process: не открылась страница - спросим в следующий раз
    [IO.File]::WriteAllText($seenFile, $mark)
    return "отличаются ($names), ответ: $answer"
}

# Пустые значения в bundle/ пропускаем, иначе ключ пропал бы из игры
function Merge-HonStr($basePath, $ruPath) {
    $baseRaw = [IO.File]::ReadAllBytes($basePath)
    $base = Read-HonStr $baseRaw
    $ru = Read-HonStr ([IO.File]::ReadAllBytes($ruPath))

    $ruLower = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($key in $ru.Order) {
        $value = $ru.Map[$key]
        $lower = $key.ToLowerInvariant()
        if ($value -and -not $ruLower.ContainsKey($lower)) { $ruLower[$lower] = $value }
    }

    $translated = 0
    $kept = 0
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $base.Order) {
        $value = $null
        if (-not ($ru.Map.TryGetValue($key, [ref]$value) -and $value)) {
            $value = $null
            [void]$ruLower.TryGetValue($key.ToLowerInvariant(), [ref]$value)
        }
        if ($value) {
            $translated++
        } else {
            $value = $base.Map[$key]
            $kept++
        }
        $lines.Add($key + "`t`t" + $value)
    }

    $bom = if (Test-HonUtf8Bom $baseRaw) { 3 } else { 0 }
    $bytes = Join-HonBytes $baseRaw $bom ($script:Utf8.GetBytes([string]::Join("`r`n", $lines)))
    return [pscustomobject]@{ Bytes = $bytes; Translated = $translated; Kept = $kept }
}

# startup.cfg игра пишет в UTF-16LE с BOM: в другой кодировке движок его не прочтёт
function Read-HonText($path) {
    $data = [IO.File]::ReadAllBytes($path)
    if ($data.Length -ge 2 -and $data[0] -eq 0xFF -and $data[1] -eq 0xFE) {
        $enc = New-Object Text.UnicodeEncoding($false, $false); $bom = 2
    } elseif ($data.Length -ge 2 -and $data[0] -eq 0xFE -and $data[1] -eq 0xFF) {
        $enc = New-Object Text.UnicodeEncoding($true, $false); $bom = 2
    } elseif (Test-HonUtf8Bom $data) {
        $enc = $script:Utf8; $bom = 3
    } else {
        $enc = $script:Utf8; $bom = 0
    }
    $text = $enc.GetString($data, $bom, $data.Length - $bom)
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.AddRange([string[]]$text.Split([string[]]@($newline), [StringSplitOptions]::None))
    return [pscustomobject]@{
        Encoding = $enc; Raw = $data; Bom = $bom; Newline = $newline; Lines = $lines
    }
}

function Write-HonText($path, $doc) {
    $body = $doc.Encoding.GetBytes([string]::Join($doc.Newline, $doc.Lines))
    $tmp = $path + '.tmp'
    [IO.File]::WriteAllBytes($tmp, (Join-HonBytes $doc.Raw $doc.Bom $body))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Find-HonCfgLine($lines, $name) {
    $prefix = ('setsave "{0}"' -f $name).ToLowerInvariant()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim().ToLowerInvariant().StartsWith($prefix)) { return $i }
    }
    return -1
}

# Запоминаем только свои правки, а не весь файл: в нём копятся настройки игрока
function Set-HonCfg($path, $pairs, $saveTo) {
    $doc = Read-HonText $path
    $previous = [ordered]@{}
    $changed = 0
    foreach ($name in $pairs.Keys) {
        $want = 'SetSave "{0}" "{1}"' -f $name, $pairs[$name]
        $i = Find-HonCfgLine $doc.Lines $name
        if ($i -ge 0) {
            $current = $doc.Lines[$i].Trim()
            if ($current -ne $want) {
                $previous[$name] = $current
                $doc.Lines[$i] = $want
                $changed++
                Write-HonLog "startup.cfg: $name -> $($pairs[$name])"
            }
        } else {
            $previous[$name] = ''      # строки не было, при откате удалим
            $at = $doc.Lines.Count
            while ($at -gt 0 -and -not $doc.Lines[$at - 1].Trim()) { $at-- }
            $doc.Lines.Insert($at, $want)
            $changed++
            Write-HonLog "startup.cfg: $name -> $($pairs[$name]) (добавлено)"
        }
    }
    if ($changed -eq 0) { return }
    if ($previous.Count -and -not (Test-Path -LiteralPath $saveTo)) {
        $saved = $previous.Keys | ForEach-Object { "$_`t$($previous[$_])" }
        [IO.File]::WriteAllLines($saveTo, [string[]]$saved, $script:Utf8)
    }
    Write-HonText $path $doc
}

function Restore-HonCfg($path, $saved) {
    if (-not (Test-Path -LiteralPath $saved)) { return 0 }
    $doc = Read-HonText $path
    $restored = 0
    foreach ($row in [IO.File]::ReadAllLines($saved, $script:Utf8)) {
        if (-not $row.Trim()) { continue }
        $name, $original = $row.Split("`t", 2)
        $i = Find-HonCfgLine $doc.Lines $name
        if ($i -lt 0) { continue }
        if ($original) { $doc.Lines[$i] = $original } else { $doc.Lines.RemoveAt($i) }
        $restored++
    }
    Write-HonText $path $doc
    Remove-Item -LiteralPath $saved -Force
    return $restored
}

function Clear-HonCache($game) {
    foreach ($name in 'filecache', 'webcache') {
        $dir = Join-Path $game.Docs $name
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-HonLog "кеш очищен: $name"
    }
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$HonWinDir = Split-Path $PSScriptRoot -Parent
$HonRepoDir = Split-Path $HonWinDir -Parent
$HonBundleDir = Join-Path $HonRepoDir 'bundle'
$HonDataDir = Join-Path $env:LOCALAPPDATA 'hon-ru'
$HonShortcutName = 'HoN (RU).lnk'
$HonTitle = 'HoN (RU)'

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
    if ($script:HonLogFile) {
        Add-Content -LiteralPath $script:HonLogFile -Value $line -Encoding UTF8
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
        # PS 5.1 без этого не включает TLS 1.2, а GitHub без него не отвечает
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
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

# Повторяет parse_str из linux/lib/honru.py: сборки обязаны совпадать побайтно.
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

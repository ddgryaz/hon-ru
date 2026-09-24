# Лаунчер требует обновление на любой лишний файл в каталоге игры, поэтому
# строки кладутся только после "Delegating to the entry point" в его логе
# и убираются после выхода из игры

param(
    [int]$Timeout = 3600
)

. (Join-Path $PSScriptRoot 'common.ps1')

# Если игру только что закрыли, первый экземпляр ещё прибирается: подождём его
$mutex = New-Object Threading.Mutex($false, 'Local\hon-ru-apply')
try {
    if (-not $mutex.WaitOne(15000)) { exit 0 }
} catch [Threading.AbandonedMutexException] {
}

Start-HonLog 'apply.log'

function Get-HonNewestLog($logs) {
    if (-not (Test-Path -LiteralPath $logs)) { return $null }
    return Get-ChildItem -LiteralPath $logs -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc | Select-Object -Last 1
}

# Лог за время скачивания патча дорастает до мегабайтов: читаем только дописанное
function Wait-HonDelegation($game, $baseline, $timeout) {
    $marker = 'Delegating to the entry point'
    $deadline = (Get-Date).AddSeconds($timeout)
    $current = $null
    $position = 0L
    $carry = ''
    $absent = 0
    $tick = 0
    while ((Get-Date) -lt $deadline) {
        $newest = Get-HonNewestLog $game.Logs
        if ($newest -and $newest.FullName -ne $baseline) {
            if ($newest.FullName -ne $current) {
                $current = $newest.FullName
                $position = 0L
                $carry = ''
            }
            try {
                $fs = [IO.File]::Open($current, 'Open', 'Read', 'ReadWrite, Delete')
                try {
                    if ($fs.Length -gt $position) {
                        $fs.Position = $position
                        $buffer = New-Object byte[] ($fs.Length - $position)
                        $read = $fs.Read($buffer, 0, $buffer.Length)
                        $position += $read
                        $text = $carry + [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                        if ($text.Contains($marker)) { return $true }
                        $carry = $text.Substring([Math]::Max(0, $text.Length - $marker.Length))
                    }
                } finally {
                    $fs.Close()
                }
            } catch [IO.IOException] {
            }
        }
        if ((++$tick % 25) -eq 0) {
            if (Test-HonRunning) { $absent = 0 } elseif (++$absent -ge 6) { return $false }
        }
        Start-Sleep -Milliseconds 20
    }
    return $false
}

function Wait-HonExit {
    $absent = 0
    while ($absent -lt 3) {
        Start-Sleep -Seconds 1
        if (Test-HonRunning) { $absent = 0 } else { $absent++ }
    }
}

function Start-HonGame($game) {
    Write-HonLog "запускаю $($game.Exe)"
    Start-Process -FilePath $game.Exe -WorkingDirectory $game.Root | Out-Null
}

try {
    $game = Find-HonGame
} catch {
    Show-HonGameNotFound $_ 'запустите ярлык "HoN (RU)"'
    exit 1
}
Write-HonLog "игра:    $($game.Game)"
Write-HonLog "профиль: $($game.Docs)"

if (Test-HonRunning) {
    Show-HonMessage 'Игра или лаунчер уже запущены. Закройте их и запустите ярлык ещё раз.' 'OK' 'Warning' | Out-Null
    exit 0
}

$leftover = Remove-HonFiles $game
if ($leftover) { Write-HonLog "убраны остатки прошлого запуска: $leftover" }

$plan = @()
$stage = Join-Path $env:TEMP ('hon-ru-' + [guid]::NewGuid())
$archiveBefore = $null
try {
    $unpacker = Resolve-HonUnpacker
    if (-not $unpacker) {
        if ($script:HonUnpackerChoice -eq 'manual') { exit 0 }
        Write-HonLog 'распаковщика нет, играем на английском'
    } else {
        Write-HonLog "распаковщик: $($unpacker.Kind) $($unpacker.Path)"
        $item = Get-Item -LiteralPath $game.Archive
        $archiveBefore = '{0}/{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks
        Expand-HonBase $game $unpacker $stage

        $sha = [Security.Cryptography.SHA256]::Create()
        foreach ($base in $HonStrBases) {
            $ru = Join-Path $HonBundleDir ($base + '_en.str')
            $orig = Join-Path $stage ($base + '_en.str')
            if (-not (Test-Path -LiteralPath $orig)) { Write-HonLog "нет в архиве игры: $($base)_en.str"; continue }
            if (-not (Test-Path -LiteralPath $ru)) { Write-HonLog "нет в bundle/: $($base)_en.str"; continue }
            $merged = Merge-HonStr $orig $ru
            Write-HonLog ('{0,-16} переведено {1,5}, на английском {2,4}' -f $base, $merged.Translated, $merged.Kept)
            foreach ($suffix in $HonStrSuffixes) {
                $plan += [pscustomobject]@{ Path = Join-Path $game.Target ($base + $suffix); Bytes = $merged.Bytes }
            }
            [void]$sha.TransformBlock($merged.Bytes, 0, $merged.Bytes.Length, $null, 0)
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $digest = [BitConverter]::ToString($sha.Hash).Replace('-', '')

        # Русский текст подменяет английский, поэтому локаль en
        $cfg = Join-Path $game.Docs 'startup.cfg'
        if (Test-Path -LiteralPath $cfg) {
            Set-HonCfg $cfg ([ordered]@{ host_locale = 'en'; host_backuplocale = 'en' }) (Join-Path $HonDataDir 'startup.orig')
        }

        # В кеше шрифтовые атласы: чистим только при смене строк, иначе медленный старт
        $stamp = Join-Path $HonDataDir 'strings.sha'
        $previous = if (Test-Path -LiteralPath $stamp) { ([string](Get-Content -LiteralPath $stamp -Raw)).Trim() } else { '' }
        if ($previous -ne $digest) {
            Clear-HonCache $game
            Set-Content -LiteralPath $stamp -Value $digest -Encoding ASCII
        }
    }
} catch {
    Write-HonLog "ошибка подготовки перевода: $_"
    $plan = @()
    Show-HonMessage ("Не удалось подготовить перевод:`n$_`n`nИгра запустится на английском. " +
        "Подробности в $script:HonLogFile") 'OK' 'Warning' | Out-Null
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

$baseline = Get-HonNewestLog $game.Logs
if ($baseline) { $baseline = $baseline.FullName }
Start-HonGame $game
if (-not $plan) { exit 0 }

try {
    if (-not (Wait-HonDelegation $game $baseline $Timeout)) {
        Write-HonLog 'лаунчер закрыт до запуска игры'
        exit 0
    }
    Write-HonLog 'лаунчер передал управление движку'

    # Лаунчер обновил игру в этом запуске: база от старой версии, новые ключи
    # вылезли бы сырыми именами. Переводим со следующего запуска
    $item = Get-Item -LiteralPath $game.Archive
    if (('{0}/{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks) -ne $archiveBefore) {
        Write-HonLog 'игра обновилась во время запуска, перевод будет со следующего раза'
        exit 0
    }

    New-Item -ItemType Directory -Force -Path $game.Target | Out-Null
    $written = 0
    foreach ($file in $plan) {
        try {
            [IO.File]::WriteAllBytes($file.Path, $file.Bytes)
            $written++
        } catch {
            Write-HonLog "не записан $($file.Path): $_"
        }
    }
    Write-HonLog "положено файлов: $written"
    Wait-HonExit
    Write-HonLog 'игра закрыта'
} finally {
    $removed = Remove-HonFiles $game
    Write-HonLog "файлов убрано: $removed"
    $mutex.ReleaseMutex()
}

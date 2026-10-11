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
    if (-not $mutex.WaitOne(15000)) {
        # Журнал не начинаем заново: в него ещё пишет первый экземпляр
        $script:HonLogFile = Join-Path $HonDataDir 'apply.log'
        Write-HonLog 'second launch: previous apply.ps1 still running, exit'
        exit 0
    }
} catch [Threading.AbandonedMutexException] {
}

Start-HonLog 'apply.log'
# Окна скрыты: без этого необработанная ошибка не оставит следа
trap { Write-HonError 'unexpected error' $_; break }

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
    $ioError = $false
    $started = Get-Date
    while ((Get-Date) -lt $deadline) {
        $newest = Get-HonNewestLog $game.Logs
        if ($newest -and $newest.FullName -ne $baseline) {
            if ($newest.FullName -ne $current) {
                $current = $newest.FullName
                Write-HonLog "launcher log: $current"
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
                        if ($text.Contains($marker)) {
                            Write-HonLog ('launcher delegated after {0:N1} s' -f ((Get-Date) - $started).TotalSeconds)
                            return $true
                        }
                        $carry = $text.Substring([Math]::Max(0, $text.Length - $marker.Length))
                    }
                } finally {
                    $fs.Close()
                }
            } catch [IO.IOException] {
                # Лаунчер держит лог в первые миллисекунды: это не ошибка
                if (-not $ioError) { Write-HonLog "launcher log busy: $($_.Exception.Message)"; $ioError = $true }
            }
        }
        if ((++$tick % 25) -eq 0) {
            if (Test-HonRunning) { $absent = 0 } elseif (++$absent -ge 6) {
                Write-HonLog 'launcher closed before the game started'
                Write-HonLauncherLog $current
                return $false
            }
        }
        Start-Sleep -Milliseconds 20
    }
    Write-HonLog "launcher did not delegate in $timeout s"
    Write-HonLauncherLog $current
    return $false
}

# Конец лога лаунчера: почему он не дошёл до запуска игры
function Write-HonLauncherLog($path) {
    if (-not $path) {
        Write-HonLog 'launcher wrote no new log'
        return
    }
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            $reader = New-Object IO.StreamReader($fs)
            $lines = $reader.ReadToEnd() -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 20
        } finally {
            $fs.Close()
        }
        Write-HonLog "last lines of ${path}:"
        foreach ($line in $lines) { Write-HonLog "  | $line" }
    } catch {
        Write-HonError 'launcher log not read' $_
    }
}

function Wait-HonExit {
    $absent = 0
    while ($absent -lt 3) {
        Start-Sleep -Seconds 1
        if (Test-HonRunning) { $absent = 0 } else { $absent++ }
    }
}

function Start-HonGame($game) {
    $process = Start-Process -FilePath $game.Exe -WorkingDirectory $game.Root -PassThru
    Write-HonLog "started $($game.Exe), pid $($process.Id)"
}

try {
    $game = Find-HonGame
} catch {
    Show-HonGameNotFound $_ 'запустите ярлык "HoN (RU)"'
    exit 1
}

if (Test-HonRunning) {
    Write-HonRunning
    Show-HonMessage 'Игра или лаунчер уже запущены. Закройте их и запустите ярлык ещё раз.' 'OK' 'Warning' | Out-Null
    exit 0
}

$leftover = Remove-HonFiles $game
if ($leftover) { Write-HonLog "removed files left from the last run: $leftover" }

$online = Test-HonOnline
# До подготовки перевода: игрок может уйти обновляться, и она будет не нужна
if ($online) {
    try {
        Write-HonLog "scripts: $(Invoke-HonScriptsCheck)"
    } catch {
        Write-HonError 'scripts not checked' $_
        if ($_.Exception -is [TimeoutException]) { $online = $false }
    }
    if ($script:HonScriptsChoice -eq 'update') {
        Write-HonLog 'player went to update, game not started'
        exit 0
    }
}

$plan = @()
$stage = Join-Path $env:TEMP ('hon-ru-' + [guid]::NewGuid())
$archiveBefore = $null
try {
    $unpacker = Resolve-HonUnpacker
    if (-not $unpacker) {
        if ($script:HonUnpackerChoice -eq 'manual') {
            Write-HonLog 'player went to get zstd.exe, game not started'
            exit 0
        }
        Write-HonLog 'no unpacker, playing in English'
    } else {
        Write-HonLog "unpacker: $($unpacker.Kind) $($unpacker.Path)"
        if ($online) {
            try {
                Write-HonLog "translation update: $(Update-HonBundle)"
            } catch {
                Write-HonError 'translation not updated, using the previous one' $_
            } finally {
                Close-HonProgress
            }
        }
        $bundle = Get-HonBundleDir
        Write-HonLog "translation from $bundle"
        $item = Get-Item -LiteralPath $game.Archive
        $archiveBefore = '{0}/{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks
        Expand-HonBase $game $unpacker $stage

        $sha = [Security.Cryptography.SHA256]::Create()
        foreach ($base in $HonStrBases) {
            $ru = Join-Path $bundle ($base + '_en.str')
            $orig = Join-Path $stage ($base + '_en.str')
            if (-not (Test-Path -LiteralPath $orig)) { Write-HonLog "not in game archive: $($base)_en.str"; continue }
            if (-not (Test-Path -LiteralPath $ru)) { Write-HonLog "not in bundle: $($base)_en.str"; continue }
            $merged = Merge-HonStr $orig $ru
            Write-HonLog ('{0,-16} translated {1,5}, english {2,4}, {3} bytes' -f
                $base, $merged.Translated, $merged.Kept, $merged.Bytes.Length)
            foreach ($suffix in $HonStrSuffixes) {
                $plan += [pscustomobject]@{ Path = Join-Path $game.Target ($base + $suffix); Bytes = $merged.Bytes }
            }
            [void]$sha.TransformBlock($merged.Bytes, 0, $merged.Bytes.Length, $null, 0)
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $digest = [BitConverter]::ToString($sha.Hash).Replace('-', '')

        # Русский текст подменяет английский, поэтому локаль en
        $cfg = Join-Path $game.Docs 'startup.cfg'
        if (-not (Test-Path -LiteralPath $cfg)) {
            Write-HonLog "no $cfg"
        } else {
            Set-HonCfg $cfg ([ordered]@{ host_locale = 'en'; host_backuplocale = 'en' }) (Join-Path $HonDataDir 'startup.orig')
        }

        # В кеше шрифтовые атласы: чистим только при смене строк, иначе медленный старт
        $stamp = Join-Path $HonDataDir 'strings.sha'
        $previous = if (Test-Path -LiteralPath $stamp) { ([string](Get-Content -LiteralPath $stamp -Raw)).Trim() } else { '' }
        if ($previous -ne $digest) {
            Write-HonLog "strings changed: $digest"
            Clear-HonCache $game
            Set-Content -LiteralPath $stamp -Value $digest -Encoding ASCII
        }
    }
} catch {
    Write-HonError 'translation not prepared' $_
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
        exit 0
    }

    # Лаунчер обновил игру в этом запуске: база от старой версии, новые ключи
    # вылезли бы сырыми именами. Переводим со следующего запуска
    $item = Get-Item -LiteralPath $game.Archive
    $archiveAfter = '{0}/{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks
    if ($archiveAfter -ne $archiveBefore) {
        Write-HonLog "game patched during this launch ($archiveBefore -> $archiveAfter), translation from the next launch"
        exit 0
    }

    New-Item -ItemType Directory -Force -Path $game.Target | Out-Null
    $written = 0
    foreach ($file in $plan) {
        try {
            [IO.File]::WriteAllBytes($file.Path, $file.Bytes)
            $written++
        } catch {
            Write-HonError "not written $($file.Path)" $_
        }
    }
    Write-HonLog "files written: $written of $($plan.Count) to $($game.Target)"
    Wait-HonExit
    Write-HonLog 'game closed'
} finally {
    $removed = Remove-HonFiles $game
    Write-HonLog "files removed: $removed"
    $mutex.ReleaseMutex()
}

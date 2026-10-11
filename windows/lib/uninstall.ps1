# Чинит и зацикливание лаунчера на "требуется обновление": убирает остатки
# файлов перевода из каталога игры

. (Join-Path $PSScriptRoot 'common.ps1')

# Папку с данными удаление стирает, журнал кладём рядом с временными файлами
Start-HonLog 'hon-ru-uninstall.log' $env:TEMP
trap { Write-HonError 'unexpected error' $_; break }

try {
    if (Test-HonRunning) {
        Write-HonRunning
        Show-HonMessage 'Сначала закройте игру и лаунчер Juvio.' 'OK' 'Warning' | Out-Null
        exit 1
    }

    $link = Join-Path ([Environment]::GetFolderPath('Desktop')) $HonShortcutName
    if (Test-Path -LiteralPath $link) {
        Remove-Item -LiteralPath $link -Force
        Write-HonLog "shortcut removed: $link"
    }

    try {
        $game = Find-HonGame
    } catch {
        $game = $null
        Write-HonError 'game not found' $_
    }
    if ($game) {
        Write-HonLog "files removed: $(Remove-HonFiles $game)"

        $cfg = Join-Path $game.Docs 'startup.cfg'
        $saved = Join-Path $HonDataDir 'startup.orig'
        if ((Test-Path -LiteralPath $cfg) -and (Test-Path -LiteralPath $saved)) {
            Write-HonLog "startup.cfg: restored $(Restore-HonCfg $cfg $saved) values"
        } else {
            Write-HonLog "startup.cfg: nothing to restore (cfg $(Test-Path -LiteralPath $cfg), saved $(Test-Path -LiteralPath $saved))"
        }
        Clear-HonCache $game
    }

    if (Test-Path -LiteralPath $HonDataDir) {
        Remove-Item -LiteralPath $HonDataDir -Recurse -Force
        Write-HonLog "removed $HonDataDir"
    }

    Show-HonMessage ("Перевод удалён. Папку с русификатором можно удалить.`n`n" +
        "Игру запускайте родным ярлыком Juvio.") 'OK' 'Information' | Out-Null
} catch {
    Write-HonError 'uninstall failed' $_
    Show-HonMessage "Удаление не удалось:`n$_`n`nПодробности в $script:HonLogFile" 'OK' 'Error' | Out-Null
    exit 1
}

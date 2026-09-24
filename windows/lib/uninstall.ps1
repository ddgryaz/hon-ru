# Чинит и зацикливание лаунчера на "требуется обновление": убирает остатки
# файлов перевода из каталога игры

. (Join-Path $PSScriptRoot 'common.ps1')

try {
    if (Test-HonRunning) {
        Show-HonMessage 'Сначала закройте игру и лаунчер Juvio.' 'OK' 'Warning' | Out-Null
        exit 1
    }

    $link = Join-Path ([Environment]::GetFolderPath('Desktop')) $HonShortcutName
    if (Test-Path -LiteralPath $link) {
        Remove-Item -LiteralPath $link -Force
        Write-Host "ярлык удалён: $link"
    }

    try {
        $game = Find-HonGame
    } catch {
        $game = $null
        Write-Host "$_"
    }
    if ($game) {
        Write-Host "файлов удалено: $(Remove-HonFiles $game)"

        $cfg = Join-Path $game.Docs 'startup.cfg'
        $saved = Join-Path $HonDataDir 'startup.orig'
        if ((Test-Path -LiteralPath $cfg) -and (Test-Path -LiteralPath $saved)) {
            Write-Host "startup.cfg: восстановлено значений: $(Restore-HonCfg $cfg $saved)"
        }
        Clear-HonCache $game
    }

    if (Test-Path -LiteralPath $HonDataDir) {
        Remove-Item -LiteralPath $HonDataDir -Recurse -Force
    }

    Show-HonMessage ("Перевод удалён. Папку с русификатором можно удалить.`n`n" +
        "Игру запускайте родным ярлыком Juvio.") 'OK' 'Information' | Out-Null
} catch {
    Show-HonMessage "Удаление не удалось:`n$_" 'OK' 'Error' | Out-Null
    exit 1
}

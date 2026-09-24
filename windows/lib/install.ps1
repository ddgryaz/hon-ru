. (Join-Path $PSScriptRoot 'common.ps1')

Start-HonLog 'install.log'

try {
    # Файлы из скачанного zip помечены "из интернета", PowerShell переспрашивает
    Get-ChildItem -LiteralPath $HonRepoDir -Recurse -File | Unblock-File

    try {
        $game = Find-HonGame
    } catch {
        Show-HonGameNotFound $_ 'запустите install.bat'
        exit 1
    }
    Write-HonLog "игра: $($game.Game)"

    # Проблему со скачиванием лучше увидеть сейчас, а не при запуске игры
    $unpacker = Resolve-HonUnpacker
    if ($unpacker) { Write-HonLog "распаковщик: $($unpacker.Kind) $($unpacker.Path)" }

    $desktop = [Environment]::GetFolderPath('Desktop')
    $link = Join-Path $desktop $HonShortcutName
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $apply = Join-Path $PSScriptRoot 'apply.ps1'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = $powershell
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$apply`""
    $shortcut.WorkingDirectory = $HonWinDir
    # Иначе консоль мелькает до -WindowStyle Hidden
    $shortcut.WindowStyle = 7
    $icon = Join-Path $game.Game 'game.ico'
    $shortcut.IconLocation = if (Test-Path -LiteralPath $icon) { "$icon,0" } else { "$($game.Exe),0" }
    $shortcut.Description = 'Heroes of Newerth с русским переводом'
    $shortcut.Save()
    Write-HonLog "ярлык: $link"

    $text = "Готово: на рабочем столе ярлык `"HoN (RU)`".`n`n" +
        "Запускайте игру через него, родной ярлык Juvio запускает игру на английском."
    if (-not $unpacker) {
        $text += "`n`nПеревод заработает, когда zstd.exe окажется в папке`n$HonWinDir"
    }
    Show-HonMessage $text 'OK' 'Information' | Out-Null
} catch {
    Write-HonLog "ошибка: $_"
    Show-HonMessage "Установка не удалась:`n$_`n`nПодробности в $script:HonLogFile" 'OK' 'Error' | Out-Null
    exit 1
}

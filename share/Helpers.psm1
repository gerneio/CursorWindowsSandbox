function Start-LogMeasure($nm, $sc) {
    Write-Host "## START[$nm]" -ForegroundColor Yellow
    Measure-Command {
        .$sc | Out-Default
    } | % { Write-Host "## END[$nm] : $($_.ToString("hh\:mm\:ss\.fff"))`n" -ForegroundColor Yellow }
}

function Set-WinTaskbarPin($shortcutPath) {
    $layoutDirectory = "$env:LOCALAPPDATA\TaskbarLayout"
    $layoutPath = "$layoutDirectory\LayoutModification.xml"
    $escapedPath = [Security.SecurityElement]::Escape($shortcutPath)

    New-Item -ItemType Directory -Path $layoutDirectory -Force | Out-Null

    $layoutContent = Get-Content $PSscriptRoot\LayoutModification.xml
    $layoutContent = $layoutContent -replace "</taskbar:TaskbarPinList>", "<taskbar:DesktopApp DesktopApplicationLinkPath=""$escapedPath"" /></taskbar:TaskbarPinList>"
    $layoutContent | Set-Content -LiteralPath $layoutPath -Encoding UTF8

    $policyPath = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"
    New-Item -Path $policyPath -Force | Out-Null
    Set-ItemProperty -Path $policyPath -Name StartLayoutFile -Value $layoutPath
    Set-ItemProperty -Path $policyPath -Name LockedStartLayout -Value 1
}

function New-WinShortcut($name, $path) {
    if (!(Test-Path $path)) { Write-Warning "Shortcut path doesn't exist: $path" }
    if (-not $script:WshShell) {
        $script:WshShell = New-Object -COMObject WScript.Shell
    }

    # desktop shortcut
    $Shortcut = $script:WshShell.CreateShortcut("$HOME\Desktop\$name.lnk")
    $Shortcut.TargetPath = $path
    $Shortcut.Save()

    # start menu shortcut
    $Shortcut = $script:WshShell.CreateShortcut("$env:appdata\Microsoft\Windows\Start Menu\Programs\$name.lnk")
    $Shortcut.TargetPath = $path
    $Shortcut.Save()

    Set-WinTaskbarPin $path
}

Export-ModuleMember -Function Start-LogMeasure, New-WinShortcut
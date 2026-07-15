#region Change default explorer settings

Set-Itemproperty -path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -value 0
Set-Itemproperty -path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Hidden' -value 1
Set-Itemproperty -path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowSuperHidden' -value 1

#endregion

#region Set dark mode (ref: https://gist.github.com/bobby-tablez/4b5f1ee02c68a93dc8312c4ff858c0a7)
function Set-DarkTheme {
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -Value 0
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "SystemUsesLightTheme" -Value 0

    Write-Host -f Yellow "Dark theme enabled"
}

function Remove-DesktopBG {
    $PolicyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"

    if (-not (Test-Path $PolicyPath)) {
        New-Item -Path $PolicyPath -Force | Out-Null
    }

    Set-ItemProperty -Path $PolicyPath -Name "Wallpaper" -Value "" -Type String

    Write-Host -f Yellow "Remove BG wallpaper"
}

Set-DarkTheme
Remove-DesktopBG

# Restart explorer to activate changes
Stop-Process -Name explorer -Force; Start-Sleep -Seconds 2; Start-Process explorer

#endregion

#region Fix slow installer issues: https://github.com/microsoft/Windows-Sandbox/issues/68#issuecomment-2684406010

Write-Host "Disable Smart App Control"

Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -Name "VerifiedAndReputablePolicyState" -Value "0"
$null | CiTool.exe -r | Out-Null

#endregion

#region Fix Test-Connection access denied error: https://github.com/PowerShell/PowerShell/issues/24668#issuecomment-2668218297

Write-Host "Reset and restart `Windows Management Instrumentation` service"

winmgmt /resetrepository
Restart-Service Winmgmt

#endregion
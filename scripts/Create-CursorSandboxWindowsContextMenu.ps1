# =========================================================================
# --- CONFIGURATION VARIABLES ---
# =========================================================================
$MenuText = "Open with Cursor Sandbox"
$RegistryKeyName  = "CursorSandbox"

# 1. The main program executable
$TargetExecutable = "pwsh.exe"
$MyScript = Join-Path $PSScriptRoot "Start-CursorSandbox.ps1"
$MyScriptArgs = "-MappedFolder"

if (-not (Test-Path -LiteralPath $MyScript)) {
    Write-Error "Start-CursorSandbox.ps1 not found next to this script: $MyScript"
    exit 1
}
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Error "pwsh.exe not found on PATH. Install PowerShell 7+ before registering the context menu."
    exit 1
}

# 2. Any flags, switches, or script files passed before the folder path
#    (Leave blank or use "" if your executable doesn't need them)
$PreArguments     = "-NoProfile -ExecutionPolicy Bypass -File `"$MyScript`" $MyScriptArgs"
# =========================================================================

# Define registry pathways
$FolderKey     = "HKCU:\Software\Classes\Directory\shell\$RegistryKeyName"
$BackgroundKey = "HKCU:\Software\Classes\Directory\Background\shell\$RegistryKeyName"

# Dynamically compile the universal execution strings with strict nested quote boundaries
$FolderCommandString     = "`"$TargetExecutable`" $PreArguments `"%1`""
$BackgroundCommandString = "`"$TargetExecutable`" $PreArguments `"%V`""

# Clean up whitespace if no pre-arguments are used
$FolderCommandString     = $FolderCommandString.Replace("  ", " ").Trim()
$BackgroundCommandString = $BackgroundCommandString.Replace("  ", " ").Trim()

# 1. APPLY TO FOLDER ICON (Targeting an actual folder item)
If (!(Test-Path $FolderKey)) { New-Item -Path $FolderKey -Force | Out-Null }
Set-ItemProperty -Path $FolderKey -Name "(Default)" -Value $MenuText
$FolderCmdPath = "$FolderKey\command"
If (!(Test-Path $FolderCmdPath)) { New-Item -Path $FolderCmdPath -Force | Out-Null }
Set-ItemProperty -Path $FolderCmdPath -Name "(Default)" -Value $FolderCommandString

# 2. APPLY TO FOLDER BACKGROUND (Targeting empty space inside)
If (!(Test-Path $BackgroundKey)) { New-Item -Path $BackgroundKey -Force | Out-Null }
Set-ItemProperty -Path $BackgroundKey -Name "(Default)" -Value $MenuText
$BackgroundCmdPath = "$BackgroundKey\command"
If (!(Test-Path $BackgroundCmdPath)) { New-Item -Path $BackgroundCmdPath -Force | Out-Null }
Set-ItemProperty -Path $BackgroundCmdPath -Name "(Default)" -Value $BackgroundCommandString

# 3. REFRESH EXPLORER
# Stop-Process -Name explorer -Force
Write-Host "Success! Created context action: $MenuText" -ForegroundColor Green

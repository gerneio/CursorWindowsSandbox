param([Parameter(Mandatory)][string]$CursorCommit)

$scriptName = Split-Path -Leaf $PSCommandPath

if (Test-Path "$HOME\desktop\Done-$scriptName.txt") { Write-Host "${scriptName}: Already installed"; return }

Start-Transcript $HOME\desktop\Running-$scriptName.txt

$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';

Import-Module "$PSScriptRoot\Helpers.psm1"

$st = Get-Date

Write-Host "${scriptName}: $st" -ForegroundColor Green

#################################################################################################

Start-LogMeasure "Install-SandboxHotFixes" {
    ."$PSScriptRoot\Install-SandboxHotFixes.ps1"
}

Start-LogMeasure "Install-WinGet" {
    ."$PSScriptRoot\Install-WinGet.ps1"
}

Start-LogMeasure "Install-WinTerminal" {
    ."$PSScriptRoot\Install-WinTerminal.ps1"
}

Start-LogMeasure "Add Shortcuts" {
    New-WinShortcut "Terminal" (Get-Item "$env:ProgramFiles\Windows Terminal\terminal-*\WindowsTerminal.exe").FullName

    # Restart explorer to activate changes
    Stop-Process -Name explorer -Force
}

Start-LogMeasure "Install-CursorServer" {
    # Installs it but doesn't run it (host cursor IDE will take care of that)
    # TODO: cache installer
    &"$PSScriptRoot\Install-CursorServer.ps1" -Commit $CursorCommit
}

Start-LogMeasure "Updating: ssh auth keys" {
    $authorizedKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
    [System.IO.Directory]::CreateDirectory((Split-Path $authorizedKeys)) | Out-Null
    if (Test-Path -LiteralPath $authorizedKeys) {
        Remove-Item -LiteralPath $authorizedKeys -Force
    }
    New-Item -ItemType SymbolicLink -Path $authorizedKeys -Target "$PSScriptRoot\.ssh-host\id_ed25519_winsandbox.pub" | Out-Null
}

Start-LogMeasure "Installing software via winget" {
    $SoftwareToInstall = @(
        "Microsoft.PowerShell"
        "Microsoft.OpenSSH.Preview"
    );

    foreach ($Software in $SoftwareToInstall) {
        Start-LogMeasure $Software {
            WinGet.exe install $software --silent --force --accept-source-agreements --accept-package-agreements --disable-interactivity --source winget
        }
    }

    if (Test-path "$PSScriptRoot\winget-apps.json") {
        Start-LogMeasure "winget-apps.json" {
            WinGet.exe import -i "$PSScriptRoot\winget-apps.json" --accept-source-agreements --accept-package-agreements --disable-interactivity
        }
    }

    # Telemetry optouts
    [Environment]::SetEnvironmentVariable("DOTNET_CLI_TELEMETRY_OPTOUT", "1", "User");
    [Environment]::SetEnvironmentVariable("POWERSHELL_TELEMETRY_OPTOUT", "1", "User");
}

#################################################################################################

Write-Host "## Total Execution : $(((Get-Date) - $st).ToString("hh\:mm\:ss\.fff"))`n" -ForegroundColor Yellow

Stop-Transcript

Rename-Item -Path $HOME\desktop\Running-$scriptName.txt -NewName $HOME\desktop\Done-$scriptName.txt
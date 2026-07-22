param([Parameter(Mandatory)][string]$CursorCommit)

$scriptName = Split-Path -Leaf $PSCommandPath

if (Test-Path "$HOME\desktop\Done-$scriptName.txt") { Write-Host "${scriptName}: Already installed"; return }

Start-Transcript $HOME\desktop\Running-$scriptName.txt

$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';

Import-Module "$PSScriptRoot\Helpers.psm1"
Import-Module "$PSScriptRoot\PathShims.psm1"

$hooksPath = Join-Path $PSScriptRoot 'SandboxInstallHooks.psm1'
if (Test-Path -LiteralPath $hooksPath) {
    Import-Module -Name $hooksPath -Force
}

function Invoke-OptionalInstallHook {
    param([Parameter(Mandatory)][ValidateSet(
        'Invoke-SandboxInstallStarted',
        'Invoke-SandboxInstallBeforeCursor',
        'Invoke-SandboxInstallAfterCursor',
        'Invoke-SandboxInstallCompleted'
    )][string]$Name)

    if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) { return }
    Start-LogMeasure "Hook $Name" { & $Name }
}

$st = Get-Date

Write-Host "${scriptName}: $st" -ForegroundColor Green

#################################################################################################

Start-LogMeasure "Install-SandboxHotFixes" {
    ."$PSScriptRoot\Install-SandboxHotFixes.ps1"
}

Invoke-OptionalInstallHook -Name Invoke-SandboxInstallStarted

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

Invoke-OptionalInstallHook -Name Invoke-SandboxInstallBeforeCursor

Start-LogMeasure "Install-CursorServer" {
    # Installs it but doesn't run it (host cursor IDE will take care of that)
    # TODO: cache installer
    &"$PSScriptRoot\Install-CursorServer.ps1" -Commit $CursorCommit
}

if (Test-Path "$PSScriptRoot\cursor-extensions.json") {
    Start-LogMeasure "Install cursor extensions" {
        $cursorServerCmd = Get-ChildItem -Path "$HOME\.cursor-server\bin" -Recurse -Filter "cursor-server.cmd" |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $cursorServerCmd) {
            throw "Could not find cursor-server.cmd under $HOME\.cursor-server\bin"
        }

        # Disables unnecessary depreciation warnings when calling cursor/node
        $env:NODE_OPTIONS = "--no-warnings";

        $extensions = Get-Content -LiteralPath "$PSScriptRoot\cursor-extensions.json" -Raw | ConvertFrom-Json
        foreach ($ext in $extensions) {
            Start-LogMeasure $ext {
                $installTarget = $ext
                $downloadedVsix = $null
                if ([System.Uri]::IsWellFormedUriString($ext, [System.UriKind]::Absolute)) {
                    $downloadedVsix = Join-Path $env:TEMP "$([guid]::NewGuid()).vsix"
                    Write-Host "Downloading VSIX: $ext -> $downloadedVsix"
                    Invoke-WebRequest -Uri $ext -OutFile $downloadedVsix
                    $installTarget = $downloadedVsix
                }

                try {
                    & $cursorServerCmd --install-extension $installTarget --force
                }
                finally {
                    if ($downloadedVsix -and (Test-Path -LiteralPath $downloadedVsix)) {
                        Remove-Item -LiteralPath $downloadedVsix -Force
                    }
                }
            }
        }
    }
}

Invoke-OptionalInstallHook -Name Invoke-SandboxInstallAfterCursor

Start-LogMeasure "Updating: ssh auth keys" {
    $authorizedKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
    [System.IO.Directory]::CreateDirectory((Split-Path $authorizedKeys)) | Out-Null
    if (Test-Path -LiteralPath $authorizedKeys) {
        Remove-Item -LiteralPath $authorizedKeys -Force
    }
    New-Item -ItemType SymbolicLink -Path $authorizedKeys -Target "$PSScriptRoot\.ssh-host\id_ed25519_winsandbox.pub" | Out-Null
}

Start-LogMeasure "Installing software via winget" {
    # Telemetry optouts
    [Environment]::SetEnvironmentVariable("DOTNET_CLI_TELEMETRY_OPTOUT", "1", "User");
    [Environment]::SetEnvironmentVariable("POWERSHELL_TELEMETRY_OPTOUT", "1", "User");

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
            Invoke-PathShimRefresh -ArgumentList "$PSScriptRoot\winget-apps.json" {
                param($ImportFile)
                WinGet.exe import -i $ImportFile --accept-source-agreements --accept-package-agreements --disable-interactivity
            }
        }
    }
}

Invoke-OptionalInstallHook -Name Invoke-SandboxInstallCompleted

#################################################################################################

Write-Host "## Total Execution : $(((Get-Date) - $st).ToString("hh\:mm\:ss\.fff"))`n" -ForegroundColor Yellow

Stop-Transcript

Rename-Item -Path $HOME\desktop\Running-$scriptName.txt -NewName $HOME\desktop\Done-$scriptName.txt
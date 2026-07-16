#Requires -Version 5.1
<#
.SYNOPSIS
  Download and install CursorWindowsSandbox from GitHub.

.DESCRIPTION
  Load the installer, then call Install-CursorWindowsSandbox (named params work normally):

    irm https://raw.githubusercontent.com/gerneio/CursorWindowsSandbox/main/install.ps1 | iex; Install-CursorWindowsSandbox

  With options:

    irm https://raw.githubusercontent.com/gerneio/CursorWindowsSandbox/main/install.ps1 | iex; Install-CursorWindowsSandbox -RegisterContextMenu -Force

.PARAMETER InstallPath
  Destination folder for the repo. If omitted (and -Force is not set), you are prompted
  to confirm the default (%USERPROFILE%\source\repos\CursorWindowsSandbox) or type a
  different path.

.PARAMETER RegisterContextMenu
  After install, run scripts\Create-CursorSandboxWindowsContextMenu.ps1 to add
  "Open with Cursor Sandbox" to Explorer.

.PARAMETER Force
  Overwrite InstallPath if it already exists, and skip the install-path confirmation
  prompt when InstallPath was not passed. Without this, the installer fails early if
  the path already exists.
#>

New-Module -Name CursorWindowsSandboxBootstrap -ScriptBlock {
    function Install-CursorWindowsSandbox {
        [CmdletBinding()]
        param(
            [string]$InstallPath = (Join-Path $env:USERPROFILE 'source\repos\CursorWindowsSandbox'),
            [switch]$RegisterContextMenu,
            [switch]$Force
        )

        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'

        $RepoZipUrl = 'https://github.com/gerneio/CursorWindowsSandbox/archive/refs/heads/main.zip'
        $ZipLeaf = 'CursorWindowsSandbox-main'

        if (-not $PSBoundParameters.ContainsKey('InstallPath') -and -not $Force) {
            Write-Host "Install path: $InstallPath"
            $response = Read-Host "Press Enter to confirm, or type a different path"
            if (-not [string]::IsNullOrWhiteSpace($response)) {
                $InstallPath = $response.Trim().Trim('"')
            }
        }

        $InstallPath = [System.IO.Path]::GetFullPath($InstallPath)
        if ((Test-Path -LiteralPath $InstallPath) -and -not $Force) {
            throw "Install path already exists: $InstallPath. Pass -Force to overwrite."
        }

        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("CursorWindowsSandbox-install-" + [guid]::NewGuid().ToString('N'))
        $zipPath = Join-Path $tempDir 'main.zip'

        try {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

            Write-Host "Downloading CursorWindowsSandbox..."
            Invoke-WebRequest -Uri $RepoZipUrl -OutFile $zipPath -UseBasicParsing

            Write-Host "Extracting..."
            Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force

            $extracted = Join-Path $tempDir $ZipLeaf
            if (-not (Test-Path -LiteralPath $extracted)) {
                throw "Expected extracted folder not found: $extracted"
            }

            $parent = Split-Path -Parent $InstallPath
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            if (Test-Path -LiteralPath $InstallPath) {
                Write-Host "Removing existing install at $InstallPath..."
                Remove-Item -LiteralPath $InstallPath -Recurse -Force
            }

            Move-Item -LiteralPath $extracted -Destination $InstallPath
            Write-Host "Installed to $InstallPath" -ForegroundColor Green

            if ($RegisterContextMenu) {
                $contextScript = Join-Path $InstallPath 'scripts\Create-CursorSandboxWindowsContextMenu.ps1'
                if (-not (Test-Path -LiteralPath $contextScript)) {
                    throw "Context menu script not found: $contextScript"
                }

                # Child process (not &-invoke): the context script calls exit, which would tear down this session.
                $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
                Write-Host "Registering Explorer context menu..."
                $output = & $shell -NoProfile -ExecutionPolicy Bypass -File $contextScript 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    $detail = if (-not [string]::IsNullOrWhiteSpace($output)) { "`n" + $output.TrimEnd() } else { '' }
                    Write-Warning "Context menu registration finished with exit code $LASTEXITCODE.$detail`nYou can re-run:`n  $contextScript"
                }
            }
            else {
                Write-Host "Tip: add -RegisterContextMenu to also install the Explorer entry." -ForegroundColor DarkGray
            }

            Write-Host ""
            Write-Host "Next: .\scripts\Start-CursorSandbox.ps1 -MappedFolder 'C:\path\to\project'" -ForegroundColor Cyan
            Write-Host "  (from $InstallPath)"
        }
        finally {
            if (Test-Path -LiteralPath $tempDir) {
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Export-ModuleMember -Function Install-CursorWindowsSandbox
} | Import-Module -Force

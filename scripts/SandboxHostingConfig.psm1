<#
.SYNOPSIS
    Read <install>/.sandbox/config.json and return launch settings for the given -MappedFolder.
#>

function Get-SandboxHostingConfigPath {
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.sandbox\config.json'))
}

function Read-SandboxHostingConfigFile {
    $configPath = Get-SandboxHostingConfigPath
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Verbose "No config at $configPath"
        return $null
    }

    try {
        return Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    } catch {
        throw "Failed to parse ${configPath}: $($_.Exception.Message)"
    }
}

function Get-ConfigEntryForMappedFolder {
    param(
        [object]$Config,
        [Parameter(Mandatory)]
        [string]$MappedFolder
    )

    if (-not $Config) {
        return $null
    }

    $normalized = [System.IO.Path]::GetFullPath($MappedFolder)
    foreach ($prop in $Config.PSObject.Properties) {
        $expanded = [Environment]::ExpandEnvironmentVariables($prop.Name)

        # Skip reserved/non-path top-level keys (e.g. "global")
        if (-not [System.IO.Path]::IsPathRooted($expanded)) {
            continue
        }

        try {
            $keyPath = [System.IO.Path]::GetFullPath($expanded)
        } catch {
            continue
        }

        if ([string]::Equals($keyPath, $normalized, [StringComparison]::OrdinalIgnoreCase)) {
            return $prop.Value
        }
    }

    return $null
}

function Resolve-FolderMappings {
    param(
        [object]$Entry,
        [Parameter(Mandatory)]
        [string]$MappedFolder
    )

    if (-not $Entry -or -not $Entry.folderMappings) {
        return @()
    }

    $primary = [System.IO.Path]::GetFullPath($MappedFolder)
    $resolved = foreach ($mapping in @($Entry.folderMappings)) {
        if (-not $mapping.path) {
            throw "folderMappings entry for '$primary' is missing required 'path'."
        }

        $mappingPath = [Environment]::ExpandEnvironmentVariables($mapping.path)

        $hostPath = if ([System.IO.Path]::IsPathRooted($mappingPath)) {
            [System.IO.Path]::GetFullPath($mappingPath)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $primary $mappingPath))
        }

        if (-not (Test-Path -LiteralPath $hostPath)) {
            throw "folderMappings path does not exist for '${primary}': $($mapping.path) -> $hostPath"
        }

        [pscustomobject]@{
            Path     = $hostPath
            Writable = [bool]($mapping.writable)
        }
    }

    return @($resolved)
}

function Resolve-SandboxRootFolder {
    param(
        [object]$Config,
        [object]$Entry
    )

    $candidate = $null
    if ($Entry -and $Entry.sandboxRootFolder) {
        $candidate = $Entry.sandboxRootFolder
    } elseif ($Config -and $Config.global -and $Config.global.sandboxRootFolder) {
        $candidate = $Config.global.sandboxRootFolder
    }
    if (-not $candidate) {
        return $null
    }

    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        throw "sandboxRootFolder must be an absolute path: $candidate"
    }

    # Guest path inside the sandbox — do not require it to exist on the host.
    return [System.IO.Path]::GetFullPath($candidate)
}

function Get-SandboxHostingConfig {
    param(
        [Parameter(Mandatory)]
        [string]$MappedFolder
    )

    $raw = Read-SandboxHostingConfigFile
    $entry = Get-ConfigEntryForMappedFolder -Config $raw -MappedFolder $MappedFolder

    [pscustomobject]@{
        FolderMappings    = @(Resolve-FolderMappings -Entry $entry -MappedFolder $MappedFolder)
        SandboxRootFolder = Resolve-SandboxRootFolder -Config $raw -Entry $entry
    }
}

Export-ModuleMember -Function 'Get-SandboxHostingConfig'

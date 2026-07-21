<#
.SYNOPSIS
    Share host folders into a Windows Sandbox session (primary + optional extras).
#>

function Get-CommonAncestorPath {
    param([string[]]$Paths)

    if (-not $Paths -or $Paths.Count -eq 0) {
        throw "Get-CommonAncestorPath requires at least one path."
    }

    $normalized = @(
        $Paths | ForEach-Object {
            [System.IO.Path]::GetFullPath($_).TrimEnd('\')
        }
    )

    $partsList = [System.Collections.Generic.List[string[]]]::new()
    foreach ($n in $normalized) {
        $partsList.Add([string[]]@($n -split '\\'))
    }

    $minLen = ($partsList | ForEach-Object { $_.Length } | Measure-Object -Minimum).Minimum
    $common = [System.Collections.Generic.List[string]]::new()

    for ($i = 0; $i -lt $minLen; $i++) {
        $segment = $partsList[0][$i]
        $mismatch = $false
        foreach ($p in $partsList) {
            if (-not [string]::Equals($p[$i], $segment, [StringComparison]::OrdinalIgnoreCase)) {
                $mismatch = $true
                break
            }
        }
        if ($mismatch) {
            break
        }
        [void]$common.Add($segment)
    }

    if ($common.Count -eq 0) {
        throw "Mapped folders do not share a common ancestor (different drives?): $($normalized -join ', ')"
    }

    $ancestor = if ($common.Count -eq 1 -and $common[0] -match '^[A-Za-z]:$') {
        $common[0] + '\'
    } else {
        $common -join '\'
    }

    $root = [System.IO.Path]::GetPathRoot($ancestor)
    if ([string]::Equals($ancestor.TrimEnd('\'), $root.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Mapped folders share only drive root '$root'; narrow folderMappings so they share a deeper common parent."
    }

    return $ancestor
}

function Get-HierarchySandboxPath {
    param(
        [Parameter(Mandatory)]
        [string]$HostPath,

        [Parameter(Mandatory)]
        [string]$Ancestor,

        [Parameter(Mandatory)]
        [string]$SandboxRootFolder
    )

    $hostFull = [System.IO.Path]::GetFullPath($HostPath).TrimEnd('\')
    $ancestorFull = [System.IO.Path]::GetFullPath($Ancestor).TrimEnd('\')

    if (-not $hostFull.StartsWith($ancestorFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Host path '$hostFull' is not under common ancestor '$ancestorFull'."
    }

    $ancestorLeaf = Split-Path $ancestorFull -Leaf
    $relative = if ($hostFull.Length -eq $ancestorFull.Length) {
        ''
    } else {
        $hostFull.Substring($ancestorFull.Length).TrimStart('\')
    }

    if ($relative) {
        return Join-Path $SandboxRootFolder (Join-Path $ancestorLeaf $relative)
    }
    return Join-Path $SandboxRootFolder $ancestorLeaf
}

function Mount-SandboxFolder {
    param(
        [Parameter(Mandatory)]
        [guid]$Id,

        [Parameter(Mandatory)]
        [string]$HostPath,

        [Parameter(Mandatory)]
        [string]$SandboxPath,

        [switch]$AllowWrite
    )

    if ($AllowWrite) {
        # TODO: prompt to confirm that this will allow the sandbox to write to this folder
        Write-Warning "Mapping folder as writable:`n`t$HostPath <> $SandboxPath"
        $null = wsb share --id $Id --host-path $HostPath --sandbox-path $SandboxPath --allow-write
    } else {
        Write-Host "Mapping folder as read-only:`n`t$HostPath <> $SandboxPath"
        $null = wsb share --id $Id --host-path $HostPath --sandbox-path $SandboxPath
    }
}

function Mount-MappedFolders {
    param(
        [Parameter(Mandatory)]
        [guid]$Id,

        [Parameter(Mandatory)]
        [string]$PrimaryHostPath,

        [Parameter(Mandatory)]
        [string]$SandboxRootFolder,

        [object[]]$FolderMappings
    )

    $primarySandboxPath = $null

    if (-not $FolderMappings -or $FolderMappings.Count -eq 0) {
        $primarySandboxPath = Join-Path $SandboxRootFolder (Split-Path $PrimaryHostPath -Leaf)
        Mount-SandboxFolder -Id $Id -HostPath $PrimaryHostPath -SandboxPath $primarySandboxPath -AllowWrite
    } else {
        $allHostPaths = @($PrimaryHostPath) + @($FolderMappings | ForEach-Object { $_.Path })
        $ancestor = Get-CommonAncestorPath -Paths $allHostPaths
        Write-Verbose "Common ancestor for mapped folders: $ancestor"

        $primarySandboxPath = Get-HierarchySandboxPath `
            -HostPath $PrimaryHostPath `
            -Ancestor $ancestor `
            -SandboxRootFolder $SandboxRootFolder
        Mount-SandboxFolder -Id $Id -HostPath $PrimaryHostPath -SandboxPath $primarySandboxPath -AllowWrite

        $sharedHosts = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        [void]$sharedHosts.Add([System.IO.Path]::GetFullPath($PrimaryHostPath))

        foreach ($mapping in $FolderMappings) {
            $hostFull = [System.IO.Path]::GetFullPath($mapping.Path)
            if (-not $sharedHosts.Add($hostFull)) {
                Write-Verbose "Skipping duplicate folderMappings path: $hostFull"
                continue
            }

            $sandboxPath = Get-HierarchySandboxPath `
                -HostPath $hostFull `
                -Ancestor $ancestor `
                -SandboxRootFolder $SandboxRootFolder
            Mount-SandboxFolder -Id $Id -HostPath $hostFull -SandboxPath $sandboxPath -AllowWrite:$mapping.Writable
        }
    }

    # Open root folder on sandbox for visibility
    $null = wsb exec --id $Id -r ExistingLogin -c "cmd.exe /c start $SandboxRootFolder"

    return $primarySandboxPath
}

Export-ModuleMember -Function 'Mount-MappedFolders'

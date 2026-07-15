#region Install WinGet, used https://learn.microsoft.com/en-us/windows/package-manager/winget/#install-winget-on-windows-sandbox

<#
Write-Host "Installing WinGet PowerShell module from PSGallery..."
Install-PackageProvider -Name NuGet -Force | Out-Null
Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
Write-Host "Using Repair-WinGetPackageManager cmdlet to bootstrap WinGet..."
Repair-WinGetPackageManager # repair is super slow (see: https://github.com/microsoft/Windows-Sandbox/issues/62)
#>

# Quicker winget install: https://github.com/microsoft/Windows-Sandbox/issues/62#issuecomment-2675894311
."$PSScriptRoot\Install-WinGetQuick.ps1"


# MS store not available on sandbox anyhow
winget source remove msstore

# So we can manually cache package installs
winget settings --enable LocalManifestFiles

Write-Host "Winget installed"

#endregion
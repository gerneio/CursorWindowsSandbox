$keyPath = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\.ssh\id_ed25519_winsandbox")
$pubKeyPath = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\share\.ssh-host\id_ed25519_winsandbox.pub")

if (Test-Path $keyPath) { return }

if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    throw "ssh-keygen was not found"
}

New-Item -ItemType Directory -Path (Split-Path $keyPath) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path $pubKeyPath) -Force | Out-Null

ssh-keygen -t ed25519 -f $keyPath -N ""

Move-Item "$keyPath.pub" -Destination $pubKeyPath -Force

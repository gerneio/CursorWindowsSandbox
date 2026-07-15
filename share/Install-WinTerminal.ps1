$terminalZip = "C:\PackageCache\Terminal.zip"

if (!(Test-Path $terminalZip)) {
    Write-Host "Downloading Windows Terminal..."
    $ProgressPreference = 'SilentlyContinue'; # speeds things up
    Invoke-WebRequest "https://aka.ms/terminal-canary-zip-x64" -OutFile $terminalZip
}

Expand-Archive $terminalZip -DestinationPath "$env:ProgramFiles\Windows Terminal"
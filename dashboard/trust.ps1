# Trust the Novacore Local CA on this Windows machine, so Chrome and Edge accept
# the HTTPS certificates of the Novacore server it came from. Downloaded from
# that server's dashboard. Right-click it and choose Run with PowerShell.
# Adds the CA for the current user only, so it doesn't need an administrator.

$ErrorActionPreference = 'Stop'

$pem = @'
{{CA_PEM}}
'@
$fingerprint = '{{CA_SHA256}}'

$file = Join-Path $env:TEMP 'novacore-ca.crt'
Set-Content -Path $file -Value $pem -Encoding Ascii
try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($file)
    Write-Host 'Novacore Local CA'
    Write-Host "SHA-256 fingerprint: $fingerprint"
    Write-Host 'Check that it matches the one on the dashboard.'
    Write-Host "Windows will ask you to confirm. Check the thumbprint is $($cert.Thumbprint), then click Yes."
    try {
        Import-Certificate -FilePath $file -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    } catch {
        Write-Host $_.Exception.Message
    }

    if (Get-ChildItem Cert:\CurrentUser\Root | Where-Object Thumbprint -eq $cert.Thumbprint) {
        Write-Host 'Added to the Windows certificate store. Restart your browser if it was already open.'
    } else {
        Write-Host 'The CA was not added. Run this again and click Yes in the Windows dialog.'
    }
} finally {
    Remove-Item $file -ErrorAction SilentlyContinue
}
Read-Host 'Press Enter to close'

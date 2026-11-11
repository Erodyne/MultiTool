# ============================================================
#  Firma digitale di MultiTool
#  Richiede un certificato di firma del codice (Code Signing)
#  installato in Cert:\CurrentUser\My o su token USB.
#  Uso:  powershell -ExecutionPolicy Bypass -File Firma-MultiTool.ps1 [-Thumbprint <impronta>]
# ============================================================
param([string]$Thumbprint, [string]$TimestampServer = 'http://timestamp.digicert.com')

$root  = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$certs = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.NotAfter -gt (Get-Date) })
if ($Thumbprint) { $certs = @($certs | Where-Object { $_.Thumbprint -eq $Thumbprint }) }
if (-not $certs.Count) { Write-Host 'Nessun certificato di firma del codice valido trovato.' -ForegroundColor Red; exit 1 }
$cert = if ($certs.Count -eq 1) { $certs[0] } else { $certs | Out-GridView -Title 'Scegli il certificato' -OutputMode Single }
if (-not $cert) { exit 1 }
Write-Host "Certificato: $($cert.Subject)  (scade il $($cert.NotAfter.ToString('dd/MM/yyyy')))" -ForegroundColor Cyan

foreach ($f in 'MultiTool.ps1', 'MultiTool.exe') {
    $p = Join-Path $root $f
    if (-not (Test-Path $p)) { continue }
    $r = Set-AuthenticodeSignature -FilePath $p -Certificate $cert -TimestampServer $TimestampServer -HashAlgorithm SHA256
    $col = if ($r.Status -eq 'Valid') { 'Green' } else { 'Yellow' }
    Write-Host ("{0,-16} {1}" -f $f, $r.Status) -ForegroundColor $col
}
Write-Host "`nNota: dopo la firma non modificare MultiTool.ps1, altrimenti la firma non è più valida." -ForegroundColor Gray

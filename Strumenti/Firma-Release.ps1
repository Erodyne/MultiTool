<#
  Firma delle release per Erodyne Suite (RSA 3072, SHA-256).

  1) Una volta sola:   .\Firma-Release.ps1 -NuovaChiave
     Crea "erodyne-firma-PRIVATA.xml" (tienila offline, MAI su GitHub) e stampa la chiave pubblica:
     incollala in Catalog.ReleaseKey (src\Catalog.cs) e ricompila la suite.
  2) A ogni release:   .\Firma-Release.ps1 -File MultiTool-Setup-2026.11.20.1.exe
     Crea "MultiTool-Setup-2026.11.20.1.exe.sig": caricalo nella release insieme all'installer.
#>
param([switch]$NuovaChiave, [string]$File, [string]$Chiave = "$PSScriptRoot\erodyne-firma-PRIVATA.xml")
$ErrorActionPreference = 'Stop'
if ($NuovaChiave) {
    if (Test-Path $Chiave) { throw "Esiste già $Chiave: non sovrascrivo una chiave in uso." }
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
    $rsa.PersistKeyInCsp = $false
    Set-Content -Path $Chiave -Value $rsa.ToXmlString($true) -Encoding ascii
    Write-Host "Chiave privata: $Chiave  (salvala su una chiavetta, fuori da GitHub)" -ForegroundColor Yellow
    Write-Host "`nChiave pubblica da incollare in Catalog.ReleaseKey:`n" -ForegroundColor Cyan
    Write-Host $rsa.ToXmlString($false)
    return
}
if (-not $File) { throw 'Indica -File <installer> oppure -NuovaChiave' }
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
$rsa.PersistKeyInCsp = $false
$rsa.FromXmlString((Get-Content $Chiave -Raw))
$hash = [Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes((Resolve-Path $File)))
$sig = $rsa.SignHash($hash, [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
Set-Content -Path "$File.sig" -Value ([Convert]::ToBase64String($sig)) -Encoding ascii
Write-Host "Firmato: $File.sig"

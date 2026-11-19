<#
  Firma delle release per Erodyne Suite (RSA 3072, SHA-256).

  1) Una volta sola:   .\Firma-Release.ps1 -NuovaChiave
     Crea "erodyne-firma-PRIVATA.xml" (tienila offline, MAI su GitHub) e stampa la chiave pubblica:
     incollala in Catalog.ReleaseKey (src\Catalog.cs) e ricompila la suite.
  2) A ogni release:   .\Firma-Release.ps1 -File MultiTool-Setup-2026.11.20.1.exe -Programma multitool -Versione 2026.11.20.1
     Crea "MultiTool-Setup-2026.11.20.1.exe.sig": caricalo nella release insieme all'installer.
     -Programma: multitool | remostation | acquisizione      -Versione: uguale al tag della release (senza "v").
     La firma vale solo per quel programma e quella versione.
#>
param([switch]$NuovaChiave, [string]$File, [ValidateSet('multitool','remostation','acquisizione')][string]$Programma, [string]$Versione,
      [string]$Chiave = "$PSScriptRoot\erodyne-firma-PRIVATA.xml")
$ErrorActionPreference = 'Stop'
if ($NuovaChiave) {
    if (Test-Path $Chiave) { throw "Esiste già ${Chiave}: non sovrascrivo una chiave in uso." }
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
    $rsa.PersistKeyInCsp = $false
    Set-Content -Path $Chiave -Value $rsa.ToXmlString($true) -Encoding ascii
    Write-Host "Chiave privata: $Chiave  (salvala su una chiavetta, fuori da GitHub)" -ForegroundColor Yellow
    Write-Host "`nChiave pubblica da incollare in Catalog.ReleaseKey:`n" -ForegroundColor Cyan
    Write-Host $rsa.ToXmlString($false)
    return
}
if (-not $File -or -not $Programma -or -not $Versione) { throw 'Indica -File <installer> -Programma <nome> -Versione <x.y.z>, oppure -NuovaChiave' }
if ($Versione -notmatch '^\d+(\.\d+)*$') { throw 'Versione: solo numeri e punti, es. 2026.11.20.1' }
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
$rsa.PersistKeyInCsp = $false
$rsa.FromXmlString((Get-Content $Chiave -Raw))
$sha = [Security.Cryptography.SHA256]::Create()
$fileHash = ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes((Resolve-Path $File))))).Replace('-', '').ToLower()
$msg = "erodyne-release-1|$Programma|$Versione|$fileHash"
$sig = $rsa.SignHash($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($msg)), [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
Set-Content -Path "$File.sig" -Value ([Convert]::ToBase64String($sig)) -Encoding ascii
Write-Host "Firmato: $File.sig  ($Programma $Versione)"

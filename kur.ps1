<#
    TeknikSuite - web onyukleyici / bootstrap
    Sunucuda yayinlanir, istemcide su sekilde calistirilir:

        irm https://domain.com/program | iex

    Parametreli kullanim:

        & ([scriptblock]::Create((irm https://domain.com/program))) -Zorla -Kisayol

    NOT: Bu dosya BOM'SUZ UTF-8 olarak yayinlanmalidir. BOM, "irm | iex"
    zincirinde metnin basina U+FEFF ekler ve ayristirici hata verir.
    Sunucu bu dosyayi "text/plain; charset=utf-8" ile sunmalidir.
    Bu nedenle dosya icerigi bilincli olarak ASCII'dir.
#>
[CmdletBinding()]
param(
    # Paketlerin yayinlandigi kok adres (Yayinla.ps1 tarafindan doldurulur)
    [string]$Kaynak,
    # Kurulum klasoru
    [string]$Kok,
    # Surum ayni olsa bile yeniden indir
    [switch]$Zorla,
    # Kurulumu kaldir
    [switch]$Kaldir,
    # Masaustune kisayol olustur
    [switch]$Kisayol,
    # Sadece kur, uygulamayi baslatma
    [switch]$Calistirma,
    # Uygulama kapanana kadar bekle
    [switch]$Bekle
)

$ErrorActionPreference = 'Stop'
$VarsayilanKaynak = 'https://raw.githubusercontent.com/aorking4824-hash/ts/main'

# ----------------------------------------------------------------- Ortam ---
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$ProgressPreference = 'SilentlyContinue'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
}

function Yaz {
    param([string]$Metin, [string]$Renk = 'Gray', [string]$On = '  ')
    Write-Host ($On + $Metin) -ForegroundColor $Renk
}
function Adim  { param([string]$Metin) Yaz $Metin 'Cyan'   '>> ' }
function Tamam { param([string]$Metin) Yaz $Metin 'Green'  ' + ' }
function Uyari { param([string]$Metin) Yaz $Metin 'Yellow' ' ! ' }
function Hata  { param([string]$Metin) Yaz $Metin 'Red'    ' x ' }

function Get-Boyut {
    param([double]$B)
    $u = @('B','KB','MB','GB'); $i = 0
    while ($B -ge 1024 -and $i -lt 3) { $B = $B / 1024; $i++ }
    return ('{0:N1} {1}' -f $B, $u[$i])
}

Write-Host ''
Write-Host '  ===============================================' -ForegroundColor DarkCyan
Write-Host '   TEKNIK SUITE  -  web kurulum' -ForegroundColor White
Write-Host '  ===============================================' -ForegroundColor DarkCyan
Write-Host ''

# ------------------------------------------------------------ On kontrol ---
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Hata 'Bu uygulama yalnizca Windows uzerinde calisir.'
    return
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Hata ('PowerShell 5.1 veya ustu gerekli. Mevcut surum: {0}' -f $PSVersionTable.PSVersion)
    return
}

if (-not $Kaynak) {
    if ($env:TEKNIKSUITE_KAYNAK) { $Kaynak = $env:TEKNIKSUITE_KAYNAK }
    elseif ($VarsayilanKaynak -notlike '@@*') { $Kaynak = $VarsayilanKaynak }
    else {
        Hata 'Kaynak adres tanimli degil. Bu dosya Yayinla.ps1 ile uretilmelidir.'
        Yaz  'Gecici cozum: -Kaynak https://domain.com/tekniksuite parametresini verin.' 'DarkGray'
        return
    }
}
$Kaynak = $Kaynak.TrimEnd('/')

if (-not $Kok) {
    if ($env:TEKNIKSUITE_KOK) { $Kok = $env:TEKNIKSUITE_KOK }
    else { $Kok = Join-Path $env:LOCALAPPDATA 'TeknikSuite' }
}

$Giris      = Join-Path $Kok 'TeknikSuite.ps1'
$DurumDosya = Join-Path $Kok '.kurulum.json'

# -------------------------------------------------------------- Kaldirma ---
if ($Kaldir) {
    Adim ('Kaldiriliyor: {0}' -f $Kok)
    if (-not (Test-Path -LiteralPath $Kok)) { Uyari 'Kurulum bulunamadi.'; return }
    if (-not $Zorla) {
        $c = Read-Host '  Gunlukler ve yedekler dahil her sey silinsin mi? (e/H)'
        if ($c -notmatch '^(e|E|y|Y)') { Yaz 'Vazgecildi.' 'DarkGray'; return }
    }
    $kisa = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Teknik Suite.lnk'
    if (Test-Path -LiteralPath $kisa) { Remove-Item -LiteralPath $kisa -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $Kok -Recurse -Force
    Tamam 'Kaldirildi.'
    return
}

# --------------------------------------------------------------- Manifest --
$manifestUrl = '{0}/surum.json?_={1}' -f $Kaynak, ([DateTime]::UtcNow.Ticks)
Adim 'Surum bilgisi aliniyor...'
try {
    $manifest = Invoke-RestMethod -Uri $manifestUrl -UseBasicParsing -TimeoutSec 30 -Headers @{ 'Cache-Control' = 'no-cache' }
} catch {
    Hata ('Surum bilgisi alinamadi: {0}' -f $_.Exception.Message)
    Yaz  ('Adres: {0}' -f $manifestUrl) 'DarkGray'
    return
}
if (-not $manifest.surum -or -not $manifest.paket -or -not $manifest.sha256) {
    Hata 'surum.json eksik alan iceriyor (surum / paket / sha256).'
    return
}
$paketUrl = $manifest.paket
if ($paketUrl -notmatch '^https?://') { $paketUrl = '{0}/{1}' -f $Kaynak, $paketUrl.TrimStart('/') }
Tamam ('Yayindaki surum: {0}' -f $manifest.surum)

# ------------------------------------------------------- Mevcut kurulum ----
$mevcut = $null
if (Test-Path -LiteralPath $DurumDosya) {
    try { $mevcut = Get-Content -LiteralPath $DurumDosya -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
$guncelMi = ($mevcut -and $mevcut.surum -eq $manifest.surum -and (Test-Path -LiteralPath $Giris))

if ($guncelMi -and -not $Zorla) {
    Tamam ('Kurulum guncel ({0}) - indirme atlandi.' -f $mevcut.surum)
} else {
    if ($mevcut) { Yaz ('Yuklu surum: {0}' -f $mevcut.surum) 'DarkGray' }

    $gecici = Join-Path ([System.IO.Path]::GetTempPath()) ('TeknikSuite_' + [Guid]::NewGuid().ToString('N'))
    $zip    = Join-Path $gecici 'paket.zip'
    $hazir  = Join-Path $gecici 'paket'
    New-Item -ItemType Directory -Path $gecici -Force | Out-Null

    try {
        Adim 'Paket indiriliyor...'
        Invoke-WebRequest -Uri $paketUrl -OutFile $zip -UseBasicParsing -TimeoutSec 300
        Tamam ('Indirildi: {0}' -f (Get-Boyut (Get-Item -LiteralPath $zip).Length))

        Adim 'Butunluk dogrulaniyor...'
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($hash -ne ($manifest.sha256 -replace '\s','').ToUpperInvariant()) {
            Hata 'SHA-256 dogrulamasi basarisiz. Paket bozuk veya degistirilmis olabilir.'
            Yaz ('Beklenen: {0}' -f $manifest.sha256) 'DarkGray'
            Yaz ('Bulunan : {0}' -f $hash) 'DarkGray'
            return
        }
        Tamam 'Dogrulandi.'

        Adim 'Paket aciliyor...'
        try {
            Expand-Archive -LiteralPath $zip -DestinationPath $hazir -Force
        } catch {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $hazir)
        }
        # Paket tek bir ust klasor icine sarilmissa iceri gir
        if (-not (Test-Path -LiteralPath (Join-Path $hazir 'TeknikSuite.ps1'))) {
            $alt = Get-ChildItem -LiteralPath $hazir -Directory | Select-Object -First 1
            if ($alt -and (Test-Path -LiteralPath (Join-Path $alt.FullName 'TeknikSuite.ps1'))) { $hazir = $alt.FullName }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $hazir 'TeknikSuite.ps1'))) {
            Hata 'Paket icinde TeknikSuite.ps1 bulunamadi.'
            return
        }

        Adim ('Kuruluyor: {0}' -f $Kok)
        foreach ($d in @('Data','Logs','Backup')) {
            $p = Join-Path $Kok $d
            if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
        }
        # Kullanicinin duzenlemis olabilecegi uygulama listesini sakla
        $uyg = Join-Path $Kok 'Data\uygulamalar.json'
        if (Test-Path -LiteralPath $uyg) {
            $yedek = Join-Path $Kok ('Backup\uygulamalar_{0}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Copy-Item -LiteralPath $uyg -Destination $yedek -Force -ErrorAction SilentlyContinue
        }
        # Eski kod dosyalarini temizle (Logs / Backup korunur)
        foreach ($d in @('Modules','UI')) {
            $p = Join-Path $Kok $d
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
        Copy-Item -Path (Join-Path $hazir '*') -Destination $Kok -Recurse -Force

        # Internet'ten indirilen dosyalardaki bolge isaretini kaldir
        Get-ChildItem -LiteralPath $Kok -Recurse -Include '*.ps1', '*.psm1', '*.psd1', '*.bat', '*.xaml' -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue

        [pscustomobject]@{
            surum  = $manifest.surum
            tarih  = (Get-Date).ToString('s')
            kaynak = $Kaynak
            sha256 = $hash
        } | ConvertTo-Json | Set-Content -LiteralPath $DurumDosya -Encoding UTF8

        Tamam ('Kuruldu: surum {0}' -f $manifest.surum)
    } finally {
        Remove-Item -LiteralPath $gecici -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------- Kisayol ----
if ($Kisayol) {
    try {
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Teknik Suite.lnk'
        $ws  = New-Object -ComObject WScript.Shell
        $s   = $ws.CreateShortcut($lnk)
        $s.TargetPath       = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $s.Arguments        = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $Giris
        $s.WorkingDirectory = $Kok
        $s.IconLocation     = 'shell32.dll,21'
        $s.Description      = 'Teknik Suite'
        $s.Save()
        Tamam 'Masaustu kisayolu olusturuldu.'
    } catch { Uyari ('Kisayol olusturulamadi: {0}' -f $_.Exception.Message) }
}

# -------------------------------------------------------------- Calistir ----
if ($Calistirma) {
    Write-Host ''
    Tamam ('Hazir. Baslatmak icin: {0}' -f (Join-Path $Kok 'Baslat.bat'))
    return
}

$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ($PSVersionTable.PSEdition -ne 'Core' -and (Test-Path -LiteralPath (Join-Path $PSHOME 'powershell.exe'))) {
    $psExe = Join-Path $PSHOME 'powershell.exe'
}
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

Adim 'Teknik Suite baslatiliyor (yonetici izni istenecek)...'
$p = Start-Process -FilePath $psExe -WorkingDirectory $Kok -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $Giris)
)
if ($Bekle -and $p) { $p.WaitForExit() }
Write-Host ''

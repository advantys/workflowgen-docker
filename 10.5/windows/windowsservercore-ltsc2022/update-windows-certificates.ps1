#Requires -Version 5.1
<#
.SYNOPSIS
Updates Microsoft-managed distrust inside a Windows container image.
.DESCRIPTION
Run during an image build, not on a host. Windows Update's CTL transport uses
HTTP; the signed CTL, its Microsoft signing chain and every SST member are
authenticated before importing anything. No trusted roots or update policies
are added or changed. -VerifyOnly is an offline, read-only image check.

References:
https://learn.microsoft.com/windows-server/administration/windows-commands/certutil
https://learn.microsoft.com/windows/win32/api/wincrypt/nf-wincrypt-certfindsubjectinctl
https://emudhra.we-have-a-problem.com/impacted-intermediates.json
#>
[CmdletBinding()]
param([switch]$VerifyOnly)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Eight compromised intermediate keys, including all sixteen published
# eMudhra-issued and cross-signed certificate variants (2026-10-21 snapshot).
$script:CompromisedCertificateSha256 = @(
    '42C4ACCD12C4F59597925E1A08A7A90102608543809308D50EC427E118BA1493'
    '45A883F349AEDFD5F3A649B5498FFB121712BA8B448F3F2A91DBC5A766FCDDBE'
    '98B896625C0C230ADEEC3EB2CF6AAD5001ECF9156A68644E82374CE5833BC25B'
    '5F1DED4DD590AF74631290CF073B122A2AAC6A1FA479778A0BD43579BD832699'
    'E7568FE6E12331F4FD7DE61DA4C7559D0F8EB192A218D4741A3BA75184333838'
    '579480AEA166290BD3C643589E795FC0D0E54E86505D180F1DFF99EFD3199512'
    '0164D7CEAE5BB909C272AF151FF44B1177AE9B47D9424B94F1D9558C30934D19'
    '62B7F9868263F72F6911FC78CEAF72C1979158B7368BF648683BB2AA39B02E72'
    'CB6E15165AC802E9B3F993F16C25D41F4E81C21EBDE71AE1B012AC00BF9C7C3F'
    '7485B51C0ED192878FA1D2F948FB529AE1842CC5086C4B67F7BE5B2039DE9489'
    '432EC25F0D28DE9006D97BF752F17BBB2CD41F669933FCB072D9A1148D0261F3'
    'FD9D5C2DBBD4995AB69B8D50C439D9527B00529199C2FD01B2174EB58F07021F'
    '9E39DE2881273ACC225A149C72BA3E0F51424963669AB633EE1DC7DF5DB067B4'
    'A496E23AC0CAB8155FC9B117B97EAE368EFCBB9041AEC8804D5A308D2D01C2D8'
    '4B2460A466F95FD40113BCDCCA2CEB29B3B093921DE45474DA7DF48874C630B1'
    '84112972B8E59D14560AE7E7119654474AAD119990CF3722BFC1E3B91615E1FD'
)

function Get-CertificateSha256 {
    param([Parameter(Mandatory = $true)]$Certificate)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($Certificate.RawData))).Replace('-', '') }
    finally { $sha256.Dispose() }
}

function Assert-IncidentCertificatesBlocked {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Certificates)
    $present = @{}
    foreach ($certificate in $Certificates) { $present[(Get-CertificateSha256 $certificate)] = $true }
    $missing = @($script:CompromisedCertificateSha256 | Where-Object { -not $present.ContainsKey($_) })
    if ($missing.Count -ne 0) {
        throw "Microsoft Disallowed store is missing $($missing.Count) compromised certificate variants: $($missing -join ', ')."
    }
}

function Get-MachineDisallowedCertificates {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Disallowed', 'LocalMachine')
    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly -bor
                    [System.Security.Cryptography.X509Certificates.OpenFlags]::OpenExistingOnly)
        return @($store.Certificates)
    }
    finally { $store.Close() }
}

function Invoke-CertutilChecked {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    & certutil.exe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "certutil $($Arguments[0]) failed with exit code $LASTEXITCODE." }
}

function Get-VerifiedCtlCms {
    param([Parameter(Mandatory = $true)][byte[]]$EncodedCtl)
    # Verify signature and shape only. The production caller additionally
    # requires the online Microsoft signing chain and the signed age window.
    Add-Type -AssemblyName System.Security
    $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms
    $cms.Decode($EncodedCtl)
    if ($cms.ContentInfo.ContentType.Value -ne '1.3.6.1.4.1.311.10.1' -or $cms.SignerInfos.Count -ne 1) {
        throw 'Expected one signed Microsoft certificate trust list.'
    }
    $cms.CheckSignature($true)
    return $cms
}

function Assert-MicrosoftCtlSigningRoot {
    param([Parameter(Mandatory = $true)]$Certificate)
    # Microsoft Root Certificate Authority 2010; its SHA256 is published in
    # Microsoft's PKI audit reports. A publisher change requires review.
    if ((Get-CertificateSha256 $Certificate) -ne 'DF545BF919A2439C36983B54CDFC903DFA4F37D3996D8D84B4C31EEC6F3C163E') {
        throw 'The CTL signer is not anchored by the approved Microsoft root.'
    }
}

function Assert-MicrosoftCtlSignature {
    param([Parameter(Mandatory = $true)][byte[]]$EncodedCtl)
    $cms = Get-VerifiedCtlCms $EncodedCtl
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    try {
        $chain.ChainPolicy.ExtraStore.AddRange($cms.Certificates)
        [void]$chain.ChainPolicy.ApplicationPolicy.Add((New-Object System.Security.Cryptography.Oid('1.3.6.1.4.1.311.10.3.9')))
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(30)
        if (-not $chain.Build($cms.SignerInfos[0].Certificate)) {
            throw "Microsoft CTL signing chain validation failed: $($chain.ChainStatus.Status -join ', ')."
        }
        $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
        Assert-MicrosoftCtlSigningRoot $root
    }
    finally { $chain.Dispose() }
}

function Initialize-CtlMembershipApi {
    if ('WorkflowGen.Certificates.CtlMembership' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace WorkflowGen.Certificates {
    public static class CtlMembership {
        [StructLayout(LayoutKind.Sequential)]
        private struct Blob { public uint Size; public IntPtr Data; }
        [StructLayout(LayoutKind.Sequential)]
        private struct Algorithm {
            [MarshalAs(UnmanagedType.LPStr)] public string Oid;
            public Blob Parameters;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Subject { public Algorithm Algorithm; public Blob Identifier; }
        [StructLayout(LayoutKind.Sequential)]
        private struct Usage { public uint Count; public IntPtr Identifiers; }
        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime {
            public uint Low; public uint High;
            public long Value { get { return ((long)High << 32) | Low; } }
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct CtlInfo {
            public uint Version; public Usage Usage; public Blob ListIdentifier;
            public Blob SequenceNumber; public FileTime ThisUpdate; public FileTime NextUpdate;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct CtlContext {
            public uint Encoding; public IntPtr Encoded; public uint Length; public IntPtr Info;
        }
        [DllImport("crypt32.dll", SetLastError = true)]
        private static extern IntPtr CertCreateCTLContext(uint encoding, byte[] encoded, uint length);
        [DllImport("crypt32.dll", SetLastError = true)]
        private static extern IntPtr CertFindSubjectInCTL(uint encoding, uint subjectType,
            ref Subject subject, IntPtr context, uint flags);
        [DllImport("crypt32.dll", SetLastError = true)]
        private static extern bool CertGetCertificateContextProperty(IntPtr certificate,
            uint property, byte[] data, ref uint length);
        [DllImport("crypt32.dll")]
        private static extern bool CertFreeCTLContext(IntPtr context);

        public static DateTime[] GetValidity(byte[] encodedCtl) {
            IntPtr context = CertCreateCTLContext(0x10001, encodedCtl, (uint)encodedCtl.Length);
            if (context == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                CtlContext header = (CtlContext)Marshal.PtrToStructure(context, typeof(CtlContext));
                CtlInfo info = (CtlInfo)Marshal.PtrToStructure(header.Info, typeof(CtlInfo));
                return new DateTime[] {
                    DateTime.FromFileTimeUtc(info.ThisUpdate.Value),
                    DateTime.FromFileTimeUtc(info.NextUpdate.Value)
                };
            } finally { CertFreeCTLContext(context); }
        }

        public static bool Contains(byte[] encodedCtl, IntPtr certificate) {
            IntPtr context = CertCreateCTLContext(0x10001, encodedCtl, (uint)encodedCtl.Length);
            if (context == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                // Windows Disallowed CTLs identify either the certificate's
                // signature hash (15) or its public-key MD5 (25). These are
                // vendor CTL lookup identifiers, not our certificate pins.
                foreach (uint property in new uint[] { 15, 25 }) {
                    uint length = 0;
                    if (!CertGetCertificateContextProperty(certificate, property, null, ref length))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    byte[] hash = new byte[length];
                    if (!CertGetCertificateContextProperty(certificate, property, hash, ref length))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    IntPtr data = Marshal.AllocHGlobal(hash.Length);
                    try {
                        Marshal.Copy(hash, 0, data, hash.Length);
                        Subject subject = new Subject {
                            Algorithm = new Algorithm { Oid = "1.3.6.1.4.1.311.10.11.15" },
                            Identifier = new Blob { Size = length, Data = data }
                        };
                        // CTL_ANY_SUBJECT_TYPE = 1. No local store is opened.
                        if (CertFindSubjectInCTL(0x10001, 1, ref subject, context, 0) != IntPtr.Zero)
                            return true;
                    } finally { Marshal.FreeHGlobal(data); }
                }
                return false;
            } finally { CertFreeCTLContext(context); }
        }
    }
}
'@
}

function Assert-CtlValidityWindow {
    param([Parameter(Mandatory = $true)][DateTime]$ThisUpdate,
          [Parameter(Mandatory = $true)][DateTime]$NextUpdate,
          [DateTime]$NowUtc = [DateTime]::UtcNow)
    # Microsoft's current Disallowed CTL omits NextUpdate. Bound that case to
    # 90 days after its SIGNED ThisUpdate rather than accepting indefinite
    # replay. A list older than this policy requires a new vendor list/review;
    # refreshing its download time never extends its acceptance window.
    if ($ThisUpdate -le [DateTime]::FromFileTimeUtc(0)) { throw 'CTL signed ThisUpdate is missing.' }
    if ($ThisUpdate -lt [DateTime]::Parse('2026-10-19T00:00:00Z').ToUniversalTime()) { throw 'CTL signed ThisUpdate predates the incident response list.' }
    if ($ThisUpdate -gt $NowUtc) { throw 'CTL signed ThisUpdate is in the future.' }
    if ($NextUpdate -gt [DateTime]::FromFileTimeUtc(0)) {
        if ($NextUpdate -le $ThisUpdate) { throw 'CTL signed NextUpdate does not follow ThisUpdate.' }
        if ($NowUtc -ge $NextUpdate) { throw 'CTL signed NextUpdate has expired.' }
    }
    if ($NowUtc -ge $ThisUpdate.AddDays(90)) { throw 'CTL signed ThisUpdate exceeds the 90-day replay limit.' }
}

function Assert-CtlFreshness {
    param([Parameter(Mandatory = $true)][byte[]]$EncodedCtl,
          [DateTime]$NowUtc = [DateTime]::UtcNow)
    Initialize-CtlMembershipApi
    $validity = [WorkflowGen.Certificates.CtlMembership]::GetValidity($EncodedCtl)
    Assert-CtlValidityWindow -ThisUpdate $validity[0] -NextUpdate $validity[1] -NowUtc $NowUtc
}

function Assert-SstMatchesSignedCtl {
    param([Parameter(Mandatory = $true)][byte[]]$EncodedCtl,
          [Parameter(Mandatory = $true)]$Certificates)
    Initialize-CtlMembershipApi
    if ($Certificates.Count -eq 0) { throw 'The downloaded Disallowed certificate store is empty.' }
    foreach ($certificate in $Certificates) {
        # Recreate from DER: SST extended properties are unsigned and must not
        # supply precomputed lookup hashes to CryptoAPI.
        $derCertificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$certificate.RawData)
        try {
            if (-not [WorkflowGen.Certificates.CtlMembership]::Contains($EncodedCtl, $derCertificate.Handle)) {
                throw "Downloaded certificate $($certificate.Thumbprint) is not covered by the authenticated Microsoft CTL."
            }
        }
        finally { $derCertificate.Dispose() }
    }
}

function Assert-WindowsContainer {
    # Refuse accidental execution on a development machine or build host.
    $containerType = [Microsoft.Win32.Registry]::GetValue(
        'HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control', 'ContainerType', $null)
    if ($containerType -isnot [int]) { throw 'Certificate updates are restricted to Windows containers.' }
}

function Update-WindowsCertificates {
    param([switch]$VerifyOnly)
    if ($VerifyOnly) {
        Assert-IncidentCertificatesBlocked @(Get-MachineDisallowedCertificates)
        Write-Host 'Verified all 16 compromised certificate variants in LocalMachine Disallowed (offline).'
        return
    }
    Assert-WindowsContainer

    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $workPath = Join-Path $temporaryRoot ('workflowgen-certificates-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $workPath -ItemType Directory | Out-Null
    try {
        Invoke-CertutilChecked @('-syncWithWU', $workPath)
        $cabPath = Join-Path $workPath 'disallowedcertstl.cab'
        $ctlPath = Join-Path $workPath 'disallowedcert.stl'
        $sstPath = Join-Path $workPath 'disallowedcert.sst'
        & expand.exe $cabPath $ctlPath | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Cannot expand the Microsoft Disallowed CTL ($LASTEXITCODE)." }
        $encodedCtl = [IO.File]::ReadAllBytes($ctlPath)
        Assert-MicrosoftCtlSignature $encodedCtl
        Assert-CtlFreshness $encodedCtl
        $downloadedCertificates = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        $downloadedCertificates.Import($sstPath)
        $certificates = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        foreach ($certificate in $downloadedCertificates) {
            [void]$certificates.Add((New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$certificate.RawData)))
        }
        Assert-SstMatchesSignedCtl $encodedCtl $certificates
        Assert-IncidentCertificatesBlocked @($certificates)
        # Import only authenticated DER certificates, not downloaded SST
        # metadata, cached hash properties or auxiliary private-key settings.
        [IO.File]::WriteAllBytes($sstPath, $certificates.Export(
            [System.Security.Cryptography.X509Certificates.X509ContentType]::SerializedStore))
        Invoke-CertutilChecked @('-verifyCTL', $cabPath, $workPath, $sstPath)
        Invoke-CertutilChecked @('-f', '-addstore', 'Disallowed', $sstPath)
        Assert-IncidentCertificatesBlocked @(Get-MachineDisallowedCertificates)
        Write-Host "Applied authenticated Microsoft distrust ($($certificates.Count) certificates); all 16 incident variants are blocked."
    }
    finally {
        # Delete only the unique directory created above, within the temp root.
        $resolvedWorkPath = [IO.Path]::GetFullPath($workPath)
        if ([IO.Path]::GetDirectoryName($resolvedWorkPath).TrimEnd('\') -ne $temporaryRoot.TrimEnd('\') -or
            [IO.Path]::GetFileName($resolvedWorkPath) -notmatch '^workflowgen-certificates-[0-9a-f]{32}$') {
            throw 'Refusing to remove an unexpected certificate temporary directory.'
        }
        Remove-Item -LiteralPath $resolvedWorkPath -Recurse -Force
    }
}

if ($MyInvocation.InvocationName -ne '.') { Update-WindowsCertificates -VerifyOnly:$VerifyOnly }

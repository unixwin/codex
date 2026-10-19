<#
.SYNOPSIS
    Update the WPM index entry for the codex package after a release.

.DESCRIPTION
    Rewrites the `codex` entry in unixwin/wpm-source's index.json so
    `wpm install codex` gets exactly the artifact this release built: the
    canonical package zip, with `bin/codex.exe` beside `codex-resources/` and
    `codex-path/`. The entry is created on the first run.

    The mapping is checked against the archive before the index is written. A
    mapping for a file the archive does not carry makes an install fail with
    "extracted path not found", and the opposite mistake - shipping a file
    nobody maps - silently does nothing; both have happened in this project
    (unixwin/WinuxCmd#1225).

.PARAMETER IndexPath
    Path to the wpm-source index.json to edit.

.PARAMETER Version
    Version of the release being published.

.PARAMETER ZipPath
    The canonical package zip this release produced.

.PARAMETER ReleaseTag
    Release tag the zip is attached to.

.PARAMETER Repository
    Repository holding the release (default unixwin/codex).

.PARAMETER AssetName
    Asset name inside the release (defaults to the zip file name).
#>
param(
    [Parameter(Mandatory = $true)][string]$IndexPath,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$ReleaseTag,
    [Parameter(Mandatory = $false)][string]$Repository = "unixwin/codex",
    [Parameter(Mandatory = $false)][string]$AssetName = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($AssetName)) {
    $AssetName = Split-Path -Leaf $ZipPath
}

# `to` is relative to opt/codex/ for a shim-layout package, so the payload keeps
# the layout the executable expects: codex.exe finds codex-resources/ one level
# up, exactly as in the npm platform package.
$files = @(
    [pscustomobject]@{ from = "bin/codex.exe"; to = "bin/codex.exe" }
    [pscustomobject]@{ from = "codex-resources"; to = "codex-resources"; kind = "dir" }
    [pscustomobject]@{ from = "codex-path"; to = "codex-path"; kind = "dir" }
    [pscustomobject]@{ from = "codex-package.json"; to = "codex-package.json" }
)

function Assert-ArchiveCarries {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$AssetName,
        [Parameter(Mandatory = $true)][object]$Mappings
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $names = @($archive.Entries | ForEach-Object { $_.FullName })
        foreach ($mapping in $Mappings) {
            $leaf = ($mapping.from -split '[\\/]')[-1]
            $isDirectory = $mapping.PSObject.Properties['kind'] -and $mapping.kind -eq 'dir'
            $found = if ($isDirectory) {
                $names | Where-Object { $_ -like "*/$leaf/*" -or $_ -like "$leaf/*" } | Select-Object -First 1
            }
            else {
                $names | Where-Object { $_ -like "*/$leaf" -or $_ -eq $leaf } | Select-Object -First 1
            }
            if ($null -eq $found) {
                throw "$AssetName does not contain '$($mapping.from)' (looked for '$leaf'); the index would map a file the archive does not ship."
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Set-Or-AddProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Value
    )

    if ($null -eq $Target.PSObject.Properties[$Name]) {
        $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $Target.$Name = $Value
    }
}

$index = Get-Content -Raw -LiteralPath $IndexPath | ConvertFrom-Json
$package = $index.packages | Where-Object { $_.name -eq "codex" } | Select-Object -First 1
if ($null -eq $package) {
    $package = [pscustomobject]@{ name = "codex" }
    $index.packages = @($index.packages) + $package
    Write-Host "created the codex entry in $IndexPath"
}

Set-Or-AddProperty -Target $package -Name "version" -Value $Version
Set-Or-AddProperty -Target $package -Name "kind" -Value "external"
Set-Or-AddProperty -Target $package -Name "category" -Value "developer"
Set-Or-AddProperty -Target $package -Name "license" -Value "Apache-2.0"
Set-Or-AddProperty -Target $package -Name "commands" -Value @("codex")
Set-Or-AddProperty -Target $package -Name "homepage" -Value "https://github.com/$Repository"
Set-Or-AddProperty -Target $package -Name "description" -Value (
    "Codex CLI (unofficial niu build of OpenAI Codex) as a native Windows package: " +
    "`bin/codex.exe` keeps `codex-resources/` beside itself, so the sandbox helpers " +
    "resolve as they do in the npm platform package.")

$artifact = [pscustomobject]@{}
Set-Or-AddProperty -Target $artifact -Name "type" -Value "zip"
Set-Or-AddProperty -Target $artifact -Name "layout" -Value "shim"
Set-Or-AddProperty -Target $artifact -Name "sha256" -Value (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash.ToLowerInvariant()
Set-Or-AddProperty -Target $artifact -Name "size" -Value (Get-Item -LiteralPath $ZipPath).Length
Set-Or-AddProperty -Target $artifact -Name "urls" -Value @("https://github.com/$Repository/releases/download/$ReleaseTag/$AssetName")
Set-Or-AddProperty -Target $artifact -Name "files" -Value $files

if ($null -eq $package.PSObject.Properties['artifacts']) {
    $package | Add-Member -NotePropertyName artifacts -NotePropertyValue ([pscustomobject]@{})
}
Set-Or-AddProperty -Target $package.artifacts -Name "windows-x64" -Value $artifact

Assert-ArchiveCarries -ArchivePath $ZipPath -AssetName $AssetName -Mappings $files

$index | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $IndexPath -Encoding utf8NoBOM
Write-Host "updated the codex WPM index entry to $Version ($AssetName)"

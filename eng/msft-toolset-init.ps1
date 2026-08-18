### This script initializes the toolset for a Microsoft (non source-only) build that bootstraps
### from an externally supplied SDK and/or package set, i.e. `.\build.cmd -withSdk <DIR>
### [-withPackages <DIR>]`.
###
### It is the Windows counterpart of eng/msft-toolset-init.sh. There is no source-only equivalent on
### Windows because source-build is Linux only, so this is the whole of the custom toolset support
### here.
###
### IMPORTANT: this must run before eng/common/tools.ps1 is dot-sourced. That script caches
### global.json into $GlobalJson when it loads, and InitializeDotNetCli compares
### $GlobalJson.tools.dotnet against DOTNET_INSTALL_DIR to decide whether it has to install an SDK.

# Rewrites the SDK version entries of a global.json in place. Both the "sdk"/"version" and the
# "tools"/"dotnet" entries hold the version of the SDK used to build: the MSBuild SDK resolver and
# the dotnet muxer use the former, Arcade's tools.ps1 the latter. Each substitution is scoped to the
# object that owns the key so that unrelated entries elsewhere in the file are left alone.
# Done with regex rather than ConvertTo-Json to avoid reformatting the whole file, and to keep this
# behaving identically to update_global_json_sdk_version in eng/toolset-init-common.sh.
function Update-GlobalJsonSdkVersion([string]$globalJsonFile, [string]$sdkVersion) {
  $content = Get-Content -Raw -Path $globalJsonFile

  $content = [regex]::Replace(
    $content,
    '("sdk"\s*:\s*\{[^}]*?"version"\s*:\s*")[^"]*(")',
    { param($m) $m.Groups[1].Value + $sdkVersion + $m.Groups[2].Value })

  $content = [regex]::Replace(
    $content,
    '("tools"\s*:\s*\{[^}]*?"dotnet"\s*:\s*")[^"]*(")',
    { param($m) $m.Groups[1].Value + $sdkVersion + $m.Groups[2].Value })

  Set-Content -Path $globalJsonFile -Value $content -NoNewline
}

# Rewrites a single "msbuild-sdks" entry of a global.json in place. This is how the bootstrap Arcade
# SDK gets repointed at a locally built package: MSBuild resolves SDKs named here through NuGet, so
# the version must match a package reachable from the configured sources.
function Update-GlobalJsonMSBuildSdkVersion([string]$globalJsonFile, [string]$sdkId, [string]$sdkVersion) {
  $content = Get-Content -Raw -Path $globalJsonFile
  $pattern = '("' + [regex]::Escape($sdkId) + '"\s*:\s*")[^"]*(")'

  $content = [regex]::Replace(
    $content,
    $pattern,
    { param($m) $m.Groups[1].Value + $sdkVersion + $m.Groups[2].Value })

  Set-Content -Path $globalJsonFile -Value $content -NoNewline
}

# Adds a local package source to a NuGet.config. Used to make an externally supplied package
# directory reachable by the outer VMR build, including MSBuild SDK resolution which reads the
# NuGet.config next to the project rather than any restore-time property.
# Existing sources with the same key are replaced so this is safe to call repeatedly.
function Add-NuGetSourceToConfig([string]$nuGetConfigFile, [string]$sourceName, [string]$sourcePath) {
  if (-not (Test-Path $nuGetConfigFile)) {
    throw "NuGet.config '$nuGetConfigFile' does not exist"
  }

  $content = Get-Content -Raw -Path $nuGetConfigFile
  $content = [regex]::Replace($content, '[ \t]*<add\s+key="' + [regex]::Escape($sourceName) + '"[^>]*/>\r?\n', '')
  $entry = '    <add key="' + $sourceName + '" value="' + $sourcePath + '" />'
  # Insert after <clear /> when it is present, otherwise NuGet would discard the source we just
  # added. The alternation is ordered so the <clear /> form wins when both could match.
  $content = [regex]::Replace(
    $content,
    '(<packageSources>\s*<clear\s*/>|<packageSources>)',
    { param($m) $m.Groups[1].Value + "`n" + $entry },
    1)

  Set-Content -Path $nuGetConfigFile -Value $content -NoNewline
}

# Returns the version of a package in a flat directory of .nupkg files, e.g. passing
# "Microsoft.DotNet.Arcade.Sdk" for a directory holding
# "Microsoft.DotNet.Arcade.Sdk.11.0.0-beta.26411.119.nupkg" returns "11.0.0-beta.26411.119".
# Returns $null when the package isn't present, which callers treat as "leave this one alone".
function Find-PackageVersion([string]$packagesDir, [string]$packageId) {
  $package = Get-ChildItem -Path $packagesDir -Recurse -File -Filter "$packageId.*.nupkg" -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match ('^' + [regex]::Escape($packageId) + '\.\d') } |
    Sort-Object Name |
    Select-Object -First 1

  if ($null -eq $package) {
    return $null
  }

  return $package.BaseName.Substring($packageId.Length + 1)
}

# Repoints the build at the supplied SDK and/or packages, and returns the extra MSBuild properties
# the caller has to pass along to the build.
function Initialize-MsftToolset([string]$repoRoot, [string]$customSdkDir, [string]$customPackagesDir) {
  $extraProperties = @()

  Write-Host 'Initializing Microsoft build toolset...'

  if ($customSdkDir) {
    if (-not (Test-Path $customSdkDir -PathType Container)) {
      throw "Custom SDK directory '$customSdkDir' does not exist"
    }

    $customSdkDir = (Resolve-Path $customSdkDir).Path
    $dotnetExe = Join-Path $customSdkDir 'dotnet.exe'
    if (-not (Test-Path $dotnetExe)) {
      throw "Custom SDK '$dotnetExe' does not exist"
    }

    # --list-sdks rather than --version: --version resolves through global.json, which at this point
    # still pins the SDK we are replacing, so it would fail (or silently roll forward to something
    # else) exactly when a custom SDK is supplied. A freshly extracted SDK archive holds one SDK;
    # take the last (highest) entry if there is somehow more than one.
    $sdkLines = @(& $dotnetExe --list-sdks)
    if ($LASTEXITCODE -ne 0 -or $sdkLines.Count -eq 0) {
      throw "Could not determine the SDK version of the custom SDK at '$customSdkDir'"
    }

    $sdkVersion = ($sdkLines[-1] -replace '\s*\[.*$', '').Trim()
    if (-not (Test-Path (Join-Path $customSdkDir "sdk\$sdkVersion") -PathType Container)) {
      throw "Custom SDK '$customSdkDir' does not contain 'sdk\$sdkVersion'"
    }

    Write-Host "Using custom bootstrap SDK from '$customSdkDir', version '$sdkVersion'"
    # Point the root global.json at the custom SDK. Both the dotnet muxer and Arcade's tools.ps1
    # resolve the SDK through this file, so a version that doesn't match the SDK being used fails
    # the build before anything gets built. The repositories underneath get the same treatment from
    # the UpdateGlobalJsonVersions target in repo-projects/Directory.Build.targets, which uses the
    # NETCoreSdkVersion of whatever SDK ends up running the build.
    Update-GlobalJsonSdkVersion (Join-Path $repoRoot 'global.json') $sdkVersion

    # InitializeDotNetCli in eng/common/tools.ps1 uses DOTNET_INSTALL_DIR as-is when it contains the
    # SDK version from global.json, which the rewrite above has just guaranteed. DOTNET_INSTALL_DIR
    # is also what gets handed down to the individual repo builds via
    # repo-projects/Directory.Build.props.
    $env:DOTNET_INSTALL_DIR = $customSdkDir
    $env:DOTNET_ROOT = $customSdkDir
  }

  if ($customPackagesDir) {
    if (-not (Test-Path $customPackagesDir -PathType Container)) {
      throw "Custom packages directory '$customPackagesDir' does not exist"
    }

    $customPackagesDir = (Resolve-Path $customPackagesDir).Path
    Write-Host "Using custom bootstrap packages from '$customPackagesDir'"

    # Make the packages reachable by the outer VMR build. MSBuild SDK resolution reads the
    # NuGet.config next to the project, so a restore-time property isn't enough for the
    # Microsoft.DotNet.Arcade.Sdk entry in global.json to resolve locally.
    Add-NuGetSourceToConfig (Join-Path $repoRoot 'NuGet.config') 'bootstrap-packages' $customPackagesDir

    # Repoint the bootstrap Arcade SDK at the supplied build when it contains one. Repos that build
    # before Arcade (Arcade itself and source-build-assets, see BootstrapArcadeRepos) use this
    # version rather than the Arcade built during this build.
    $arcadeVersion = Find-PackageVersion $customPackagesDir 'Microsoft.DotNet.Arcade.Sdk'
    if ($arcadeVersion) {
      Write-Host "Using bootstrap Arcade SDK version '$arcadeVersion'"
      Update-GlobalJsonMSBuildSdkVersion (Join-Path $repoRoot 'global.json') 'Microsoft.DotNet.Arcade.Sdk' $arcadeVersion
    }

    # ExtraRestoreSourcePath adds the directory to each repo's NuGet.config (see the
    # UpdateNuGetConfig target in repo-projects/Directory.Build.targets), while
    # RestoreAdditionalProjectSources covers the VMR-level projects.
    $extraProperties += "/p:ExtraRestoreSourcePath=$customPackagesDir"
    $extraProperties += "/p:RestoreAdditionalProjectSources=$customPackagesDir"
  }

  Write-Host 'Microsoft build toolset initialization complete'

  return $extraProperties
}

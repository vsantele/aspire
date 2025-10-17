<#
.SYNOPSIS
  Generate split-tests matrix JSON supporting collection-based and class-based modes.

.DESCRIPTION
  Reads *.tests.list files:
    collection mode format:
      collection:Name
      ...
      uncollected:*    (catch-all)
    class mode format:
      class:Full.Namespace.ClassName

  Builds matrix entries with fields consumed by CI:
    type                (collection | uncollected | class)
    projectName
    shortname
    name
    fullClassName (class mode only)
    testProjectPath
    extraTestArgs
    requiresNugets
    requiresTestSdk
    enablePlaywrightInstall
    testSessionTimeout
    testHangTimeout

  Defaults (if metadata absent):
    testSessionTimeout=20m
    testHangTimeout=10m
    uncollectedTestsSessionTimeout=15m
    uncollectedTestsHangTimeout=10m

.NOTES
  PowerShell 7+, cross-platform.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$TestListsDirectory,
  [Parameter(Mandatory=$true)]
  [string]$OutputDirectory,
  [Parameter(Mandatory=$false)]
  [string]$RegularTestProjectsFile = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-Metadata($file, $projectName) {
  $defaults = @{
    projectName = $projectName
    testClassNamesPrefix = $projectName
    testProjectPath = "tests/$projectName/$projectName.csproj"
    requiresNugets = 'false'
    requiresTestSdk = 'false'
    enablePlaywrightInstall = 'false'
    testSessionTimeout = '20m'
    testHangTimeout = '10m'
    uncollectedTestsSessionTimeout = '15m'
    uncollectedTestsHangTimeout = '10m'
    supportedOSes = @('windows', 'linux', 'macos')
  }
  if (-not (Test-Path $file)) { return $defaults }
  try {
    $json = Get-Content -Raw -Path $file | ConvertFrom-Json
    foreach ($k in $json.PSObject.Properties.Name) {
      $defaults[$k] = $json.$k
    }
  } catch {
    throw "Failed parsing metadata for ${projectName}: $_"
  }
  return $defaults
}

function New-EntryCollection($c,$meta) {
  $projectShortName = $meta.projectName -replace '^Aspire\.' -replace '\.Tests$'
  [ordered]@{
    type = 'collection'
    projectName = $meta.projectName
    name = $c
    shortname = "${projectShortName}_$c"
    testProjectPath = $meta.testProjectPath
    extraTestArgs = "--filter-trait `"Partition=$c`""
    requiresNugets = ($meta.requiresNugets -eq 'true')
    requiresTestSdk = ($meta.requiresTestSdk -eq 'true')
    enablePlaywrightInstall = ($meta.enablePlaywrightInstall -eq 'true')
    testSessionTimeout = $meta.testSessionTimeout
    testHangTimeout = $meta.testHangTimeout
    supportedOSes = $meta.supportedOSes
  }
}

function New-EntryUncollected($collections,$meta) {
  $filters = @()
  foreach ($c in $collections) {
    $filters += "--filter-not-trait `"Partition=$c`""
  }
  [ordered]@{
    type = 'uncollected'
    projectName = $meta.projectName
    name = 'UncollectedTests'
    shortname = 'Uncollected'
    testProjectPath = $meta.testProjectPath
    extraTestArgs = ($filters -join ' ')
    requiresNugets = ($meta.requiresNugets -eq 'true')
    requiresTestSdk = ($meta.requiresTestSdk -eq 'true')
    enablePlaywrightInstall = ($meta.enablePlaywrightInstall -eq 'true')
    testSessionTimeout = ($meta.uncollectedTestsSessionTimeout ?? $meta.testSessionTimeout)
    testHangTimeout = ($meta.uncollectedTestsHangTimeout ?? $meta.testHangTimeout)
    supportedOSes = $meta.supportedOSes
  }
}

function New-EntryClass($full,$meta) {
  $prefix = $meta.testClassNamesPrefix
  $short = $full
  if ($prefix -and $full.StartsWith("$prefix.")) {
    $short = $full.Substring($prefix.Length + 1)
  }
  [ordered]@{
    type = 'class'
    projectName = $meta.projectName
    name = $short
    shortname = $short
    fullClassName = $full
    testProjectPath = $meta.testProjectPath
    extraTestArgs = "--filter-class `"$full`""
    requiresNugets = ($meta.requiresNugets -eq 'true')
    requiresTestSdk = ($meta.requiresTestSdk -eq 'true')
    enablePlaywrightInstall = ($meta.enablePlaywrightInstall -eq 'true')
    testSessionTimeout = $meta.testSessionTimeout
    testHangTimeout = $meta.testHangTimeout
    supportedOSes = $meta.supportedOSes
  }
}

function New-EntryRegular($shortName) {
  [ordered]@{
    type = 'regular'
    projectName = "Aspire.$shortName.Tests"
    name = $shortName
    shortname = $shortName
    testProjectPath = "tests/Aspire.$shortName.Tests/Aspire.$shortName.Tests.csproj"
    extraTestArgs = ""
    requiresNugets = $false
    requiresTestSdk = $false
    enablePlaywrightInstall = $false
    testSessionTimeout = '20m'
    testHangTimeout = '10m'
    supportedOSes = @('windows', 'linux', 'macos')
  }
}

if (-not (Test-Path $TestListsDirectory)) {
  throw "Test lists directory not found: $TestListsDirectory"
}

$listFiles = @(Get-ChildItem -Path $TestListsDirectory -Filter '*.tests.list' -Recurse -ErrorAction SilentlyContinue)
if ($listFiles.Count -eq 0) {
  $empty = @{ include = @() }
  New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
  $empty | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path (Join-Path $OutputDirectory 'combined-tests-matrix.json') -Encoding UTF8
  Write-Host "Empty matrix written (no .tests.list files)."
  exit 0
}

$entries = [System.Collections.Generic.List[object]]::new()

foreach ($lf in $listFiles) {
  $fileName = $lf.Name -replace '\.tests\.list$',''
  $projectName = $fileName
  $lines = @(Get-Content $lf.FullName | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })
  $metadataPath = ($lf.FullName -replace '\.tests\.list$', '.tests.metadata.json')
  $meta = Read-Metadata $metadataPath $projectName
  if ($lines.Count -eq 0) { continue }

  if ($lines[0].StartsWith('collection:') -or $lines[0].StartsWith('uncollected:')) {
    # collection mode
    $collections = @()
    $hasUncollected = $false
    foreach ($l in $lines) {
      if ($l -match '^collection:(.+)$') { $collections += $Matches[1].Trim() }
      elseif ($l -match '^uncollected:') { $hasUncollected = $true }
    }
    foreach ($c in ($collections | Sort-Object)) {
      $entries.Add( (New-EntryCollection $c $meta) ) | Out-Null
    }
    if ($hasUncollected) {
      $entries.Add( (New-EntryUncollected $collections $meta) ) | Out-Null
    }
  } elseif ($lines[0].StartsWith('class:')) {
    # class mode
    foreach ($l in $lines) {
      if ($l -match '^class:(.+)$') {
        $entries.Add( (New-EntryClass $Matches[1].Trim() $meta) ) | Out-Null
      }
    }
  }
}

# Add regular (non-split) test projects if provided
if ($RegularTestProjectsFile -and (Test-Path $RegularTestProjectsFile)) {
  # Check if JSON file exists with full metadata
  $jsonFile = "$RegularTestProjectsFile.json"
  if (Test-Path $jsonFile) {
    $regularProjectsData = Get-Content -Raw $jsonFile | ConvertFrom-Json
    if ($regularProjectsData -isnot [Array]) {
      $regularProjectsData = @($regularProjectsData)
    }
    Write-Host "Adding $($regularProjectsData.Count) regular test project(s) from JSON"
    foreach ($proj in $regularProjectsData) {
      # Try to read metadata file for this project if it exists
      $metadataFile = $null
      if ($proj.metadataFile) {
        # metadataFile path is relative to repo root, so make it absolute
        $metadataFile = Join-Path $TestListsDirectory ".." ($proj.metadataFile -replace '^artifacts/', '')
      }

      $meta = $null
      if ($metadataFile -and (Test-Path $metadataFile)) {
        $meta = Read-Metadata $metadataFile $proj.project
        Write-Host "  Loaded metadata for $($proj.project) from $metadataFile (requiresNugets=$($meta.requiresNugets))"
      } else {
        # Use defaults if no metadata file exists
        $meta = @{
          projectName = $proj.project
          testProjectPath = $proj.fullPath
          requiresNugets = 'false'
          requiresTestSdk = 'false'
          enablePlaywrightInstall = 'false'
          testSessionTimeout = '20m'
          testHangTimeout = '10m'
          supportedOSes = ($proj.supportedOSes ?? @('windows', 'linux', 'macos'))
        }
        Write-Host "  Using default metadata for $($proj.project) (no metadata file found at $metadataFile)"
      }

      $entry = [ordered]@{
        type = 'regular'
        projectName = $proj.project
        name = $proj.shortName
        shortname = $proj.shortName
        testProjectPath = $proj.fullPath
        extraTestArgs = ""
        requiresNugets = ($meta.requiresNugets -eq 'true')
        requiresTestSdk = ($meta.requiresTestSdk -eq 'true')
        enablePlaywrightInstall = ($meta.enablePlaywrightInstall -eq 'true')
        testSessionTimeout = $meta.testSessionTimeout
        testHangTimeout = $meta.testHangTimeout
        supportedOSes = ($proj.supportedOSes ?? $meta.supportedOSes)
      }
      $entries.Add($entry) | Out-Null
    }
  } else {
    # Fallback to old behavior for backward compatibility
    $regularProjects = @(Get-Content $RegularTestProjectsFile | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })
    Write-Host "Adding $($regularProjects.Count) regular test project(s) (legacy mode)"
    foreach ($shortName in $regularProjects) {
      $entries.Add( (New-EntryRegular $shortName) ) | Out-Null
    }
  }
}

$matrix = @{ include = $entries }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$matrix | ConvertTo-Json -Depth 10 -Compress | Set-Content -Path (Join-Path $OutputDirectory 'combined-tests-matrix.json') -Encoding UTF8
Write-Host "Matrix entries: $($entries.Count)"

#!/usr/bin/env pwsh

param(
    [Parameter(Mandatory=$true)]
    [string]$BuildOs,

    [Parameter(Mandatory=$true)]
    [string]$TestsListOutputPath,

    [Parameter(Mandatory=$false)]
    [string]$TestMatrixOutputPath,

    [Parameter(Mandatory=$true)]
    [string]$ArtifactsTmpDir,

    [Parameter(Mandatory=$true)]
    [string]$RepoRoot
)

Write-Host "Processing test enumeration files for BuildOs: $BuildOs"
Write-Host "TestsListOutputPath: $TestsListOutputPath"
Write-Host "TestMatrixOutputPath: $TestMatrixOutputPath"
Write-Host "ArtifactsTmpDir: $ArtifactsTmpDir"

# Find all test enumeration files
$enumerationFiles = Get-ChildItem -Path $ArtifactsTmpDir -Filter '*.testenumeration.json' -ErrorAction SilentlyContinue

if (-not $enumerationFiles) {
    Write-Error "No test enumeration files found in $ArtifactsTmpDir"
    # Create empty output files
    "" | Set-Content $TestsListOutputPath
    if ($TestMatrixOutputPath) {
        New-Item -Path $TestMatrixOutputPath -ItemType Directory -Force | Out-Null
    }
    exit 1
}

if (-not (Test-Path $TestMatrixOutputPath)) {
    Write-Error "TestMatrixOutputPath directory does not exist: $TestMatrixOutputPath"
    exit 1
}

Write-Host "Found $($enumerationFiles.Count) test enumeration files"

# Process enumeration files
$regularTestProjects = @()
$splitTestProjects = @()

foreach ($file in $enumerationFiles) {
    try {
        $content = Get-Content -Raw $file.FullName | ConvertFrom-Json

        # Filter by BuildOs and eligibility
        if ($content.buildOs -eq $BuildOs -and $content.runOnGithubActions -eq 'true') {
            if ($content.splitTests -eq 'true') {
                $splitTestProjects += $content.shortName
            } else {
                # Store full enumeration data for regular tests
                $regularTestProjects += $content
            }
            Write-Host "  Included: $($content.shortName) (Split: $($content.splitTests))"
        } else {
            Write-Host "  Excluded: $($content.shortName) (BuildOs: $($content.buildOs), RunOnGithubActions: $($content.runOnGithubActions))"
        }
    }
    catch {
        Write-Warning "Failed to process $($file.FullName): $_"
    }
}

Write-Host "Regular test projects: $($regularTestProjects.Count)"
Write-Host "Split test projects: $($splitTestProjects.Count)"

# Create output directory if needed
$outputDir = Split-Path $TestsListOutputPath -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

# Write regular test projects list as JSON for matrix generation
if ($regularTestProjects.Count -gt 0) {
    $regularTestProjects | ConvertTo-Json -Depth 10 | Set-Content "$TestsListOutputPath.json"
}
# Also write just the short names for backward compatibility
$regularTestProjects | ForEach-Object { $_.shortName } | Set-Content $TestsListOutputPath

# Write split test projects list if any exist
if ($splitTestProjects.Count -gt 0) {
    $splitTestProjects | Select-Object -Unique | Set-Content "$TestsListOutputPath.split-projects"
    Write-Host "Split projects written to: $TestsListOutputPath.split-projects"
}
else {
    Write-Host "No split test projects found, skipping split-projects file creation"
}


Write-Host "Generating test matrices..."

# Check if TestMatrixOutputPath ends with .json (single file) or is a directory
$isJsonFile = $TestMatrixOutputPath -match '\.json$'

if ($isJsonFile) {
    # Single JSON file output - create directory for intermediate files
    $tempMatrixDir = Join-Path (Split-Path $TestMatrixOutputPath -Parent) 'temp-matrix'
    New-Item -Path $tempMatrixDir -ItemType Directory -Force | Out-Null

    # Call existing matrix generation script if split tests exist
    if ($splitTestProjects.Count -gt 0) {
        $matrixScriptPath = Join-Path $RepoRoot 'eng/scripts/generate-test-matrix.ps1'
        $testListsDir = Join-Path (Split-Path $TestsListOutputPath -Parent) 'helix'
        Write-Host "Calling matrix generation script..."
        & $matrixScriptPath -TestListsDirectory $testListsDir -OutputDirectory $tempMatrixDir -BuildOs $BuildOs -RegularTestProjectsFile $TestsListOutputPath

        # Copy the generated matrix file to the expected location
        $generatedMatrixFile = Join-Path $tempMatrixDir 'split-tests-matrix.json'
        if (Test-Path $generatedMatrixFile) {
            Copy-Item $generatedMatrixFile $TestMatrixOutputPath
            Write-Host "Matrix file copied to: $TestMatrixOutputPath"
        } else {
            Write-Warning "Expected matrix file not found at: $generatedMatrixFile"
        }

        # Clean up temporary directory
        Remove-Item $tempMatrixDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        # No split tests, create empty matrix
        '{"include":[]}' | Set-Content $TestMatrixOutputPath
        Write-Host "No split tests found, created empty matrix at: $TestMatrixOutputPath"
    }
} else {
    # Directory output (original behavior)
    New-Item -Path $TestMatrixOutputPath -ItemType Directory -Force | Out-Null

    # Call existing matrix generation script if split tests exist
    if ($splitTestProjects.Count -gt 0) {
        $matrixScriptPath = Join-Path $RepoRoot 'eng/scripts/generate-test-matrix.ps1'
        $testListsDir = Join-Path (Split-Path $TestsListOutputPath -Parent) 'helix'
        Write-Host "Calling matrix generation script..."
        & $matrixScriptPath -TestListsDirectory $testListsDir -OutputDirectory $TestMatrixOutputPath -BuildOs $BuildOs -RegularTestProjectsFile $TestsListOutputPath
    }
}

Write-Host "Test enumeration processing completed"
Write-Host "Regular projects written to: $TestsListOutputPath"
#if ($splitTestProjects.Count -gt 0) {
    #Write-Host "Split projects written to: $TestsListOutputPath.split-projects"
#}
if ($TestMatrixOutputPath) {
    Write-Host "Test matrices written to: $TestMatrixOutputPath"
}

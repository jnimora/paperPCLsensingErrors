param(
    [string]$RepositoryPath =
        "C:\Users\JNINO\Documents\GitHub\paperPCLsensingErrors"
)

# curate_paperPCLsensingErrors_figures_v3.ps1
#
# Build the canonical manuscript-figure directory from:
#   - existing validated notebook-generated PDFs; and
#   - the two recovered legacy PGFPlotsX standalone TeX sources.
#
# The script does not rerun numerical calculations. It compiles only the
# recovered TeX coordinate files for:
#   mp_index_vs_rho.pdf
#   mp_family_p01.pdf
#
# The historical mp_family_q.tex is preserved unchanged in provenance.
# A curated copy changes only legend occurrences of "q =" to "p_{01} =".
#
# Writes:
#   reproducibility\figures\manuscript
#   reproducibility\provenance\figure_curation_v1
#
# It never modifies clean_benchmark_v4 and performs no Git operation.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
}

function Assert-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required directory is missing: $Path"
    }
}

function Get-SHA256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-File $Path
    return (
        Get-FileHash -LiteralPath $Path -Algorithm SHA256
    ).Hash.ToUpperInvariant()
}

function Test-PdfHeader {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-File $Path

    $stream = [System.IO.File]::OpenRead($Path)

    try {
        $buffer = New-Object byte[] 5
        $read = $stream.Read($buffer, 0, 5)

        if ($read -ne 5) {
            return $false
        }

        $header = [System.Text.Encoding]::ASCII.GetString($buffer)
        return $header -eq "%PDF-"
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-ValidPdf {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-File $Path
    $item = Get-Item -LiteralPath $Path

    if ($item.Length -lt 1000) {
        throw "PDF is unexpectedly small ($($item.Length) bytes): $Path"
    }

    if (-not (Test-PdfHeader $Path)) {
        throw "File does not begin with a PDF header: $Path"
    }
}

function Invoke-PdfLaTeX {
    param(
        [Parameter(Mandatory = $true)][string]$PdfLaTeXPath,
        [Parameter(Mandatory = $true)][string]$TeXPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$ConsoleLogPath
    )

    Assert-File $TeXPath
    Assert-Directory $WorkingDirectory

    $texName = Split-Path -Leaf $TeXPath

    for ($pass = 1; $pass -le 2; $pass++) {
        "===== pdflatex pass ${pass}: $texName =====" |
            Out-File `
                -LiteralPath $ConsoleLogPath `
                -Encoding UTF8 `
                -Append

        # MiKTeX may invoke METAFONT while generating a missing font and
        # write perfectly normal progress text to stderr. With
        # $ErrorActionPreference = "Stop", direct native-command invocation
        # can incorrectly turn that stderr text into a PowerShell
        # NativeCommandError. Start-Process keeps stdout/stderr separate and
        # lets us judge success from the actual process exit code.
        $stdoutPath = Join-Path `
            $WorkingDirectory `
            ("pdflatex_pass_{0}_stdout.txt" -f $pass)

        $stderrPath = Join-Path `
            $WorkingDirectory `
            ("pdflatex_pass_{0}_stderr.txt" -f $pass)

        Remove-Item `
            -LiteralPath $stdoutPath, $stderrPath `
            -Force `
            -ErrorAction SilentlyContinue

        $arguments = @(
            "-interaction=nonstopmode",
            "-halt-on-error",
            $texName
        )

        $process = Start-Process `
            -FilePath $PdfLaTeXPath `
            -ArgumentList $arguments `
            -WorkingDirectory $WorkingDirectory `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -NoNewWindow `
            -Wait `
            -PassThru

        $process.WaitForExit()
        $process.Refresh()
        $exitCode = $process.ExitCode

        if (Test-Path -LiteralPath $stdoutPath) {
            "----- stdout -----" |
                Out-File `
                    -LiteralPath $ConsoleLogPath `
                    -Encoding UTF8 `
                    -Append

            Get-Content -LiteralPath $stdoutPath |
                Out-File `
                    -LiteralPath $ConsoleLogPath `
                    -Encoding UTF8 `
                    -Append
        }

        if (Test-Path -LiteralPath $stderrPath) {
            "----- stderr -----" |
                Out-File `
                    -LiteralPath $ConsoleLogPath `
                    -Encoding UTF8 `
                    -Append

            Get-Content -LiteralPath $stderrPath |
                Out-File `
                    -LiteralPath $ConsoleLogPath `
                    -Encoding UTF8 `
                    -Append
        }

        Remove-Item `
            -LiteralPath $stdoutPath, $stderrPath `
            -Force `
            -ErrorAction SilentlyContinue

        if ($exitCode -ne 0) {
            Write-Host ""
            Write-Host "pdflatex failed. Last console-output lines:"

            Get-Content `
                -LiteralPath $ConsoleLogPath `
                -Tail 100 |
                Out-Host

            throw (
                "pdflatex failed with exit code $exitCode " +
                "for $TeXPath."
            )
        }
    }
}

function Write-Utf8WithoutBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

Write-Host ""
Write-Host "=== paperPCLsensingErrors figure curation v1 ==="
Write-Host ""

$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
$repro = Join-Path $repo "reproducibility"

$notebookOutput = Join-Path `
    $repro `
    "figures\notebook_outputs"

$legacySource = Join-Path `
    $repro `
    "figures\source\mac_legacy"

$finalFigures = Join-Path `
    $repro `
    "figures\manuscript"

$finalProvenance = Join-Path `
    $repro `
    "provenance\figure_curation_v1"

Assert-Directory (Join-Path $repo ".git")
Assert-Directory $notebookOutput
Assert-Directory $legacySource

if (Test-Path -LiteralPath $finalFigures) {
    throw @"
The canonical manuscript-figure directory already exists:
    $finalFigures

Nothing has been changed. Review or rename that directory before rerunning.
"@
}

if (Test-Path -LiteralPath $finalProvenance) {
    throw @"
The figure-curation provenance directory already exists:
    $finalProvenance

Nothing has been changed. Review or rename that directory before rerunning.
"@
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tempRoot = Join-Path `
    $repro `
    ("_figure_curation_tmp_" + $timestamp)

$tempFigures = Join-Path $tempRoot "manuscript"
$tempProvenance = Join-Path $tempRoot "provenance"
$tempCompile = Join-Path $tempRoot "compile"

New-Item -ItemType Directory -Force -Path $tempFigures | Out-Null
New-Item -ItemType Directory -Force -Path $tempProvenance | Out-Null
New-Item -ItemType Directory -Force -Path $tempCompile | Out-Null

# ---------------------------------------------------------------------------
# 1. Copy the fourteen already generated manuscript PDFs.
# ---------------------------------------------------------------------------

$copyMappings = @(
    [pscustomobject]@{
        Source = "homogeneous_tie_diagnostics.pdf"
        Target = "homogeneous_tie_diagnostics.pdf"
        Transformation = "copied unchanged"
    },
    [pscustomobject]@{
        Source = "representative_lwz4_approximate_index.pdf"
        Target = "representative_lwz4_approximate_index.pdf"
        Transformation = "copied unchanged"
    },
    [pscustomobject]@{
        Source = "policy_relative_performance_by_capacity.pdf"
        Target = "policy_relative_performance_by_capacity.pdf"
        Transformation = "copied unchanged"
    },
    [pscustomobject]@{
        Source = "mp_conditional_benchmark_gap_by_size.pdf"
        Target = "mp_conditional_benchmark_gap_by_size.pdf"
        Transformation = "copied unchanged"
    },
    [pscustomobject]@{
        Source = "tildeFG_vs_z.pdf"
        Target = "tildeFG_vs_z.pdf"
        Transformation = "copied unchanged"
    },
    [pscustomobject]@{
        Source = "FG_vs_z.pdf"
        Target = "FG_vs_z.pdf"
        Transformation = "copied unchanged"
    },
    [pscustomobject]@{
        Source = "tildef_tildeg_vs_z_plot.pdf"
        Target = "tildef_tildeg_vs_z.pdf"
        Transformation =
            "copied unchanged; canonical filename drops legacy _plot suffix"
    },
    [pscustomobject]@{
        Source = "fg_vs_z_plot.pdf"
        Target = "fg_vs_z_plot.pdf"
        Transformation = "copied unchanged"
    },
    [pscustomobject]@{
        Source = "fg_diag.pdf"
        Target = "fg_diag.pdf"
        Transformation = "copied unchanged"
    },
    [pscustomobject]@{
        Source = "mp_index_vs_x.pdf"
        Target = "mp_index_vs_x.pdf"
        Transformation = "copied unchanged"
    },
    [pscustomobject]@{
        Source = "mp_family_beta.pdf"
        Target = "mp_family_beta.pdf"
        Transformation = "copied unchanged"
    },
    [pscustomobject]@{
        Source = "mp_family_kappa.pdf"
        Target = "mp_family_kappa.pdf"
        Transformation = "copied unchanged"
    },
    [pscustomobject]@{
        Source = "mp_family_rho.pdf"
        Target = "mp_family_rho.pdf"
        Transformation = "copied unchanged"
    },
    [pscustomobject]@{
        Source = "mp_index_vs_p01.pdf"
        Target = "mp_index_vs_p01.pdf"
        Transformation = "copied unchanged"
    }
)

$manifestRows = @()

foreach ($mapping in $copyMappings) {
    $sourcePath = Join-Path $notebookOutput $mapping.Source
    $targetPath = Join-Path $tempFigures $mapping.Target

    Assert-ValidPdf $sourcePath
    Copy-Item `
        -LiteralPath $sourcePath `
        -Destination $targetPath `
        -Force
    Assert-ValidPdf $targetPath

    $sourceHash = Get-SHA256 $sourcePath
    $targetHash = Get-SHA256 $targetPath

    if ($sourceHash -ne $targetHash) {
        throw (
            "A supposedly unchanged PDF copy has a different SHA-256: " +
            $mapping.Source
        )
    }

    $manifestRows += [pscustomobject]@{
        FigureBaseName =
            [System.IO.Path]::GetFileNameWithoutExtension(
                $mapping.Target
            )
        OutputFile = $mapping.Target
        SourceFile = (
            "reproducibility/figures/notebook_outputs/" +
            $mapping.Source
        )
        Transformation = $mapping.Transformation
        SourceSHA256 = $sourceHash
        OutputSHA256 = $targetHash
        OutputBytes = (
            Get-Item -LiteralPath $targetPath
        ).Length
        PDFHeaderValid = $true
    }
}

# ---------------------------------------------------------------------------
# 2. Compile the recovered mp_index_vs_rho standalone TeX source.
# ---------------------------------------------------------------------------

$pdfLaTeXCommand = Get-Command `
    pdflatex.exe `
    -ErrorAction SilentlyContinue

if ($null -eq $pdfLaTeXCommand) {
    $pdfLaTeXCommand = Get-Command `
        pdflatex `
        -ErrorAction SilentlyContinue
}

if ($null -eq $pdfLaTeXCommand) {
    throw "pdflatex was not found on PATH."
}

$pdfLaTeX = $pdfLaTeXCommand.Source

$rhoSource = Join-Path $legacySource "mp_index_vs_rho.tex"
Assert-File $rhoSource

$rhoTeX = Join-Path $tempCompile "mp_index_vs_rho.tex"
Copy-Item -LiteralPath $rhoSource -Destination $rhoTeX -Force

$rhoConsoleLog = Join-Path `
    $tempProvenance `
    "mp_index_vs_rho_pdflatex_console.txt"

Invoke-PdfLaTeX `
    -PdfLaTeXPath $pdfLaTeX `
    -TeXPath $rhoTeX `
    -WorkingDirectory $tempCompile `
    -ConsoleLogPath $rhoConsoleLog

$rhoPdf = Join-Path $tempCompile "mp_index_vs_rho.pdf"
Assert-ValidPdf $rhoPdf

Copy-Item `
    -LiteralPath $rhoPdf `
    -Destination (Join-Path $tempFigures "mp_index_vs_rho.pdf") `
    -Force

Copy-Item `
    -LiteralPath $rhoTeX `
    -Destination (Join-Path $tempFigures "mp_index_vs_rho.tex") `
    -Force

$manifestRows += [pscustomobject]@{
    FigureBaseName = "mp_index_vs_rho"
    OutputFile = "mp_index_vs_rho.pdf"
    SourceFile = (
        "reproducibility/figures/source/mac_legacy/" +
        "mp_index_vs_rho.tex"
    )
    Transformation =
        "compiled twice with pdflatex; numerical coordinates unchanged"
    SourceSHA256 = Get-SHA256 $rhoSource
    OutputSHA256 = Get-SHA256 $rhoPdf
    OutputBytes = (Get-Item -LiteralPath $rhoPdf).Length
    PDFHeaderValid = $true
}

# ---------------------------------------------------------------------------
# 3. Curate mp_family_q.tex to p01 terminology and compile it.
# ---------------------------------------------------------------------------

$familySource = Join-Path $legacySource "mp_family_q.tex"
Assert-File $familySource

$familyLines = Get-Content `
    -LiteralPath $familySource `
    -Encoding UTF8

$replacementCount = 0
$curatedLines = @()

foreach ($line in $familyLines) {
    $newLine = $line

    if ($line -match "\\addlegendentry") {
        $newLine = [regex]::Replace(
            $line,
            "(?<![A-Za-z\\])q\s*=",
            {
                param($match)
                $script:replacementCount++
                return "p_{01} ="
            }
        )
    }

    $curatedLines += $newLine
}

if ($replacementCount -lt 1) {
    throw @"
No legend occurrence of 'q =' was found in:
    $familySource

The source was not curated or compiled.
"@
}

$familyTeX = Join-Path $tempCompile "mp_family_p01.tex"
Write-Utf8WithoutBom `
    -Path $familyTeX `
    -Text (($curatedLines -join "`r`n") + "`r`n")

$familyConsoleLog = Join-Path `
    $tempProvenance `
    "mp_family_p01_pdflatex_console.txt"

Invoke-PdfLaTeX `
    -PdfLaTeXPath $pdfLaTeX `
    -TeXPath $familyTeX `
    -WorkingDirectory $tempCompile `
    -ConsoleLogPath $familyConsoleLog

$familyPdf = Join-Path $tempCompile "mp_family_p01.pdf"
Assert-ValidPdf $familyPdf

Copy-Item `
    -LiteralPath $familyPdf `
    -Destination (Join-Path $tempFigures "mp_family_p01.pdf") `
    -Force

Copy-Item `
    -LiteralPath $familyTeX `
    -Destination (Join-Path $tempFigures "mp_family_p01.tex") `
    -Force

$manifestRows += [pscustomobject]@{
    FigureBaseName = "mp_family_p01"
    OutputFile = "mp_family_p01.pdf"
    SourceFile = (
        "reproducibility/figures/source/mac_legacy/" +
        "mp_family_q.tex"
    )
    Transformation = (
        "legend-only terminology change q -> p_{01}; " +
        "compiled twice with pdflatex; coordinates unchanged"
    )
    SourceSHA256 = Get-SHA256 $familySource
    OutputSHA256 = Get-SHA256 $familyPdf
    OutputBytes = (Get-Item -LiteralPath $familyPdf).Length
    PDFHeaderValid = $true
}

# ---------------------------------------------------------------------------
# 4. Validate the complete canonical set.
# ---------------------------------------------------------------------------

$expectedBaseNames = @(
    "homogeneous_tie_diagnostics",
    "representative_lwz4_approximate_index",
    "policy_relative_performance_by_capacity",
    "mp_conditional_benchmark_gap_by_size",
    "tildeFG_vs_z",
    "FG_vs_z",
    "tildef_tildeg_vs_z",
    "fg_vs_z_plot",
    "fg_diag",
    "mp_index_vs_x",
    "mp_family_beta",
    "mp_family_kappa",
    "mp_family_rho",
    "mp_index_vs_rho",
    "mp_family_p01",
    "mp_index_vs_p01"
)

foreach ($baseName in $expectedBaseNames) {
    Assert-ValidPdf (
        Join-Path $tempFigures ($baseName + ".pdf")
    )
}

$actualBaseNames = @(
    Get-ChildItem `
        -LiteralPath $tempFigures `
        -Filter "*.pdf" `
        -File |
    ForEach-Object { $_.BaseName } |
    Sort-Object
)

$expectedSorted = @($expectedBaseNames | Sort-Object)

if (
    (Compare-Object `
        -ReferenceObject $expectedSorted `
        -DifferenceObject $actualBaseNames)
) {
    Write-Host "Expected basenames:"
    $expectedSorted | Out-Host
    Write-Host "Actual basenames:"
    $actualBaseNames | Out-Host

    throw "The canonical manuscript-figure set is incomplete."
}

$manifestPath = Join-Path `
    $tempProvenance `
    "manuscript_figures_v1.csv"

$manifestRows |
    Sort-Object FigureBaseName |
    Export-Csv `
        -LiteralPath $manifestPath `
        -NoTypeInformation `
        -Encoding UTF8

@"
Canonical manuscript-figure basename changes

The following source/manuscript names should be standardized:

1. tildef_tildeg_vs_z_plot.pdf
   -> tildef_tildeg_vs_z.pdf

2. mp_family_q.tex / mp_family_q.pdf
   -> mp_family_p01.tex / mp_family_p01.pdf

3. mp_index_vs_q.pdf
   -> mp_index_vs_p01.pdf

The first and third changes are filename normalization only.
For mp_family_p01, the raw legacy TeX source remains unchanged under
figures/source/mac_legacy. The curated source changes only legend text
from q to p_{01}; all numerical coordinates are unchanged.
"@ | Set-Content `
    -LiteralPath (
        Join-Path `
            $tempProvenance `
            "manuscript_figure_rename_map.txt"
    ) `
    -Encoding UTF8

@(
    "paperPCLsensingErrors figure curation v1"
    "Generated: $((Get-Date).ToString('o'))"
    ""
    "Repository:"
    $repo
    ""
    "pdflatex:"
    $pdfLaTeX
    ""
    "Canonical PDF count:"
    $expectedBaseNames.Count
    ""
    "Copied existing PDFs:"
    $copyMappings.Count
    ""
    "Compiled recovered TeX sources:"
    "2"
    ""
    "mp_family_q legend replacements:"
    $replacementCount
    ""
    "All expected PDFs present and valid:"
    "true"
    ""
    "Numerical calculations rerun:"
    "none"
    ""
    "Git operations performed:"
    "none"
) | Set-Content `
    -LiteralPath (
        Join-Path `
            $tempProvenance `
            "figure_curation_summary.txt"
    ) `
    -Encoding UTF8

# ---------------------------------------------------------------------------
# 5. Install only after every check has passed.
# ---------------------------------------------------------------------------

New-Item `
    -ItemType Directory `
    -Force `
    -Path (Split-Path -Parent $finalFigures) |
    Out-Null

New-Item `
    -ItemType Directory `
    -Force `
    -Path (Split-Path -Parent $finalProvenance) |
    Out-Null

Move-Item `
    -LiteralPath $tempFigures `
    -Destination $finalFigures

Move-Item `
    -LiteralPath $tempProvenance `
    -Destination $finalProvenance

if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item `
        -LiteralPath $tempRoot `
        -Recurse `
        -Force
}

Write-Host ""
Write-Host "Figure curation completed successfully."
Write-Host "Canonical figures:"
Write-Host "  $finalFigures"
Write-Host "Provenance:"
Write-Host "  $finalProvenance"
Write-Host ""
Write-Host "Canonical PDFs: $($expectedBaseNames.Count)/16"
Write-Host "No numerical calculation was rerun."
Write-Host "No Git operation was performed."
Write-Host ""
Write-Host "Current Git status:"
git -C $repo status --short --untracked-files=normal

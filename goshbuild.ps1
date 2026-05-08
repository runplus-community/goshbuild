Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-TextNoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-Sha256File {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TemplateFromSh {
    param(
        [Parameter(Mandatory = $true)][string]$ShContent,
        [Parameter(Mandatory = $true)][string]$VarName,
        [Parameter(Mandatory = $true)][string]$EndToken
    )

    $pattern = "(?ms)read -r -d '' $VarName <<'$EndToken' \|\| true\r?\n(?<body>.*?)\r?\n$EndToken"
    $match = [regex]::Match($ShContent, $pattern)
    if (-not $match.Success) {
        throw "Could not extract template '$VarName' from goshbuild.sh"
    }
    return $match.Groups["body"].Value.Replace("`r`n", "`n")
}

function Load-TarExcludes {
    param([Parameter(Mandatory = $true)][string]$SrcDir)

    $tarExcludes = @(
        "--exclude=.git"
        "--exclude=bin"
        "--exclude=conversions"
        "--exclude=out"
        "--exclude=_runner_out"
        "--exclude=archive"
        "--exclude=.*"
        "--exclude=dist"
        "--exclude=.goshbuildignore"
        "--exclude=*.goshignore.*"
        "--exclude=*.gitignore.*"
    )

    $ignoreFile = Join-Path $SrcDir ".goshbuildignore"
    if (-not (Test-Path -LiteralPath $ignoreFile -PathType Leaf)) {
        return $tarExcludes
    }

    $customCount = 0
    foreach ($line in Get-Content -LiteralPath $ignoreFile) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }
        if ($trimmed.StartsWith("#")) {
            continue
        }
        $tarExcludes += "--exclude=$trimmed"
        $customCount++
    }

    Write-Host "[goshbuild] Ignore   : $ignoreFile ($customCount custom pattern(s))"
    return $tarExcludes
}

function Invoke-VendorBeforePack {
    param([Parameter(Mandatory = $true)][string]$SrcDir)

    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        throw "[goshbuild] ERROR: go command not found on PATH (required for go mod vendor)"
    }

    Write-Host "[goshbuild] Vendor   : go mod vendor"
    Push-Location -LiteralPath $SrcDir
    $originalGoCache = $env:GOCACHE
    $isolatedGoCache = Join-Path ([System.IO.Path]::GetTempPath()) ("goshbuild-gocache-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $isolatedGoCache -Force | Out-Null
    $env:GOCACHE = $isolatedGoCache
    try {
        & go mod vendor
        if ($LASTEXITCODE -ne 0) {
            throw "[goshbuild] ERROR: go mod vendor failed"
        }
    }
    finally {
        if ([string]::IsNullOrWhiteSpace($originalGoCache)) {
            Remove-Item Env:\GOCACHE -ErrorAction SilentlyContinue
        }
        else {
            $env:GOCACHE = $originalGoCache
        }
        if (Test-Path -LiteralPath $isolatedGoCache -PathType Container) {
            Remove-Item -LiteralPath $isolatedGoCache -Recurse -Force
        }
        Pop-Location
    }

    $vendorDir = Join-Path $SrcDir "vendor"
    if (Test-Path -LiteralPath $vendorDir -PathType Container) {
        Write-Host "[goshbuild] Vendor   : $vendorDir"
    }
}

function Write-ConversionArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$SrcDir,
        [Parameter(Mandatory = $true)][string]$ModuleName,
        [Parameter(Mandatory = $true)][string]$ModuleSafe,
        [Parameter(Mandatory = $true)][string]$TarballSha256,
        [Parameter(Mandatory = $true)][string]$TarballPath,
        [Parameter(Mandatory = $true)][string]$PayloadB64Path,
        [Parameter(Mandatory = $true)][string]$RunnerStubPath,
        [Parameter(Mandatory = $true)][string]$OutRunner,
        [Parameter(Mandatory = $true)][string]$OutTest,
        [string]$PackLogPath
    )

    $conversionsDir = Join-Path (Join-Path (Join-Path $SrcDir "conversions") $ModuleSafe) $TarballSha256
    $metadataPath = Join-Path $conversionsDir "metadata.txt"
    $packTranscriptPath = Join-Path $conversionsDir "pack.transcript.raw.log"

    New-Item -ItemType Directory -Path $conversionsDir -Force | Out-Null

    Copy-Item -LiteralPath $TarballPath -Destination (Join-Path $conversionsDir "payload.tar.gz") -Force
    Copy-Item -LiteralPath $PayloadB64Path -Destination (Join-Path $conversionsDir "payload.b64.txt") -Force
    Copy-Item -LiteralPath $RunnerStubPath -Destination (Join-Path $conversionsDir "runner.stub.sh") -Force
    if (Test-Path -LiteralPath $OutRunner -PathType Leaf) {
        Copy-Item -LiteralPath $OutRunner -Destination (Join-Path $conversionsDir "runner.full.sh") -Force
    }
    if (Test-Path -LiteralPath $OutTest -PathType Leaf) {
        Copy-Item -LiteralPath $OutTest -Destination (Join-Path $conversionsDir "runner.test.sh") -Force
    }
    if ($PackLogPath -and (Test-Path -LiteralPath $PackLogPath -PathType Leaf)) {
        Copy-Item -LiteralPath $PackLogPath -Destination $packTranscriptPath -Force
    }

    $metadataLines = @(
        "module_name=$ModuleName"
        "module_safe=$ModuleSafe"
        "payload_sha256=$TarballSha256"
        "source_dir=$SrcDir"
        "runner_path=$OutRunner"
        "test_path=$OutTest"
    )
    if (Test-Path -LiteralPath $OutRunner -PathType Leaf) {
        $metadataLines += "runner_full_copy=$(Join-Path $conversionsDir 'runner.full.sh')"
    }
    if (Test-Path -LiteralPath $OutTest -PathType Leaf) {
        $metadataLines += "runner_test_copy=$(Join-Path $conversionsDir 'runner.test.sh')"
    }
    if ($PackLogPath -and (Test-Path -LiteralPath $PackLogPath -PathType Leaf)) {
        $metadataLines += "pack_transcript=$packTranscriptPath"
    }
    Write-TextNoBom -Path $metadataPath -Content (($metadataLines -join "`n") + "`n")

    Write-Host "[goshbuild] Conversions -> $conversionsDir"
    if ($PackLogPath -and (Test-Path -LiteralPath $PackLogPath -PathType Leaf)) {
        Write-Host "[goshbuild] Transcript  -> $packTranscriptPath"
    }
}

function Register-PackInCon {
    param(
        [Parameter(Mandatory = $true)][string]$SrcDir,
        [Parameter(Mandatory = $true)][string]$ConBaseDir,
        [Parameter(Mandatory = $true)][string]$ModuleName,
        [Parameter(Mandatory = $true)][string]$ModuleSafe,
        [Parameter(Mandatory = $true)][string]$TarballSha256,
        [Parameter(Mandatory = $true)][string]$OutRunner,
        [Parameter(Mandatory = $true)][string]$OutTest,
        [string]$PackLogPath
    )

    $runStamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $runId = "$runStamp-$PID"
    $conRoot = Join-Path (Join-Path (Join-Path $ConBaseDir ".con") $ModuleSafe) $TarballSha256
    $runDir = Join-Path (Join-Path $conRoot "runs") $runId
    $latestDir = Join-Path $conRoot "latest"
    $metadataPath = Join-Path $runDir "registration.env"
    $latestMetadataPath = Join-Path $latestDir "registration.env"
    $transcriptName = "conversation.transcript.raw.log"

    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    New-Item -ItemType Directory -Path $latestDir -Force | Out-Null

    if ($PackLogPath -and (Test-Path -LiteralPath $PackLogPath -PathType Leaf)) {
        Copy-Item -LiteralPath $PackLogPath -Destination (Join-Path $runDir $transcriptName) -Force
        Copy-Item -LiteralPath $PackLogPath -Destination (Join-Path $latestDir $transcriptName) -Force
    }

    $metadataLines = @(
        "registered_at_utc=$runStamp"
        "run_id=$runId"
        "module_name=$ModuleName"
        "module_safe=$ModuleSafe"
        "payload_sha256=$TarballSha256"
        "source_dir=$SrcDir"
        "runner_path=$OutRunner"
        "test_path=$OutTest"
    )
    if ($PackLogPath -and (Test-Path -LiteralPath $PackLogPath -PathType Leaf)) {
        $metadataLines += "conversation_transcript=$(Join-Path $runDir $transcriptName)"
    }

    Write-TextNoBom -Path $metadataPath -Content (($metadataLines -join "`n") + "`n")
    Copy-Item -LiteralPath $metadataPath -Destination $latestMetadataPath -Force

    Write-Host "[goshbuild] .con       -> $runDir"
}

function Show-Usage {
    Write-Host @"
Usage:
  .\goshbuild.ps1
  .\goshbuild.ps1 pack
  .\goshbuild.ps1 pack <src_dir>
  .\goshbuild.ps1 pack <src_dir> <out_runner.sh>

Notes:
  - module_safe is derived from 'module ...' in go.mod by replacing '/' and '.' with '_'
  - A .test.sh is generated alongside the runner: <out_runner.sh>.test.sh
  - go mod vendor is always executed before packing so vendor/ is included in the payload
  - Each pack run is registered under <goshbuild_dir>/.con/<module_safe>/<payload_sha256>/runs/<run_id>/
  - Raw conversion artifacts and a complete pack transcript are written under <src_dir>/conversions/<module_safe>/<payload_sha256>/
"@
    exit 1
}

function Resolve-TarCommand {
    $systemTar = Join-Path $env:WINDIR "System32\tar.exe"
    if (Test-Path -LiteralPath $systemTar -PathType Leaf) {
        return $systemTar
    }
    $tarCmd = Get-Command tar -ErrorAction SilentlyContinue
    if ($tarCmd) {
        return $tarCmd.Source
    }
    throw "ERROR: tar command not found on PATH"
}

$cmd = "pack"
$srcArg = ""
$outArg = ""

if ($args.Count -eq 0) {
    $cmd = "pack"
}
elseif ($args[0] -eq "pack") {
    if ($args.Count -ge 2) { $srcArg = $args[1] }
    if ($args.Count -ge 3) { $outArg = $args[2] }
    if ($args.Count -gt 3) { Show-Usage }
}
elseif (Test-Path -LiteralPath $args[0] -PathType Container) {
    $cmd = "pack"
    $srcArg = $args[0]
    if ($args.Count -ge 2) { $outArg = $args[1] }
    if ($args.Count -gt 2) { Show-Usage }
}
else {
    Show-Usage
}

if ($cmd -ne "pack") {
    Show-Usage
}

if ([string]::IsNullOrWhiteSpace($srcArg)) {
    $srcArg = "."
}

$srcDir = (Resolve-Path -LiteralPath $srcArg).Path
if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) {
    throw "ERROR: '$srcDir' is not a directory"
}

$goModPath = Join-Path $srcDir "go.mod"
if (-not (Test-Path -LiteralPath $goModPath -PathType Leaf)) {
    throw "ERROR: no go.mod found in '$srcDir'"
}

$moduleLine = Get-Content -LiteralPath $goModPath | Where-Object { $_ -match '^module\s+' } | Select-Object -First 1
if (-not $moduleLine) {
    throw "ERROR: could not parse module name from go.mod"
}
$moduleName = ($moduleLine -split '\s+')[1]
if ([string]::IsNullOrWhiteSpace($moduleName)) {
    throw "ERROR: could not parse module name from go.mod"
}

$moduleSafe = $moduleName -replace '[/.]', '_'

if ([string]::IsNullOrWhiteSpace($outArg)) {
    $outRunner = Join-Path $srcDir "$moduleSafe.run.sh"
}
else {
    if ([System.IO.Path]::IsPathRooted($outArg)) {
        $outRunner = [System.IO.Path]::GetFullPath($outArg)
    }
    else {
        $outRunner = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $outArg))
    }
    $outRunnerDir = Split-Path -Path $outRunner -Parent
    if ($outRunnerDir) {
        New-Item -ItemType Directory -Path $outRunnerDir -Force | Out-Null
    }
}

$outTest = "$outRunner.test.sh"

$tarCommand = Resolve-TarCommand

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("goshbuild-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$packLogFile = Join-Path $workDir "pack.transcript.raw.log"
$tarball = Join-Path $workDir "payload.tar.gz"
$payloadB64File = Join-Path $workDir "payload.b64.txt"
$resolvedRunnerStubPath = Join-Path $workDir "runner.stub.sh"

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$shPackerPath = Join-Path $scriptRoot "goshbuild.sh"
if (-not (Test-Path -LiteralPath $shPackerPath -PathType Leaf)) {
    throw "ERROR: required template source not found: $shPackerPath"
}

$transcriptStarted = $false
try {
    try {
        Start-Transcript -Path $packLogFile -Force | Out-Null
        $transcriptStarted = $true
    }
    catch {
        Write-Warning "[goshbuild] Could not start transcript: $($_.Exception.Message)"
    }

    Write-Host "[goshbuild] Module   : $moduleName"
    Write-Host "[goshbuild] Safe ID  : $moduleSafe"
    Write-Host "[goshbuild] Source   : $srcDir"
    Write-Host "[goshbuild] Output   : $outRunner"

    Invoke-VendorBeforePack -SrcDir $srcDir
    $tarExcludes = Load-TarExcludes -SrcDir $srcDir

    $tarArgs = @("-czf", $tarball) + $tarExcludes + @("-C", (Split-Path -Path $srcDir -Parent), (Split-Path -Path $srcDir -Leaf))
    & $tarCommand @tarArgs
    if ($LASTEXITCODE -ne 0) {
        throw "ERROR: tar packaging failed"
    }

    $tarballSha256 = Get-Sha256File -Path $tarball
    Write-Host "[goshbuild] Payload SHA256 : $tarballSha256"

    $payloadB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($tarball))
    Write-TextNoBom -Path $payloadB64File -Content ($payloadB64 + "`n")

    $shContent = Get-Content -LiteralPath $shPackerPath -Raw
    $runnerTemplate = Get-TemplateFromSh -ShContent $shContent -VarName "RUNNER_STUB" -EndToken "STUB_EOF"
    $testTemplate = Get-TemplateFromSh -ShContent $shContent -VarName "TEST_STUB" -EndToken "TEST_EOF"

    $resolvedRunnerStub = $runnerTemplate.Replace("%%MODULE_SAFE%%", $moduleSafe).Replace("%%TARBALL_SHA256%%", $tarballSha256).Replace("`r`n", "`n")
    $resolvedTestStub = $testTemplate.Replace("%%MODULE_SAFE%%", $moduleSafe).Replace("%%MODULE_NAME%%", $moduleName).Replace("%%RUNNER_PATH%%", $outRunner).Replace("`r`n", "`n")

    if (-not $resolvedRunnerStub.EndsWith("`n")) {
        $resolvedRunnerStub += "`n"
    }
    if (-not $resolvedTestStub.EndsWith("`n")) {
        $resolvedTestStub += "`n"
    }

    Write-TextNoBom -Path $resolvedRunnerStubPath -Content $resolvedRunnerStub
    Write-TextNoBom -Path $outRunner -Content ($resolvedRunnerStub + $payloadB64 + "`n")
    Write-TextNoBom -Path $outTest -Content $resolvedTestStub

    Write-Host "[goshbuild] Runner  -> $outRunner"
    Write-Host "   Run with: $outRunner --help"
    Write-Host "[goshbuild] Tests   -> $outTest"
    Write-Host "   Run with: bash $outTest"
}
finally {
    if ($transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            # no-op
        }
    }
}

try {
    Write-ConversionArtifacts `
        -SrcDir $srcDir `
        -ModuleName $moduleName `
        -ModuleSafe $moduleSafe `
        -TarballSha256 $tarballSha256 `
        -TarballPath $tarball `
        -PayloadB64Path $payloadB64File `
        -RunnerStubPath $resolvedRunnerStubPath `
        -OutRunner $outRunner `
        -OutTest $outTest `
        -PackLogPath $packLogFile

    Register-PackInCon `
        -SrcDir $srcDir `
        -ConBaseDir $scriptRoot `
        -ModuleName $moduleName `
        -ModuleSafe $moduleSafe `
        -TarballSha256 $tarballSha256 `
        -OutRunner $outRunner `
        -OutTest $outTest `
        -PackLogPath $packLogFile
}
finally {
    if (Test-Path -LiteralPath $workDir -PathType Container) {
        Remove-Item -LiteralPath $workDir -Recurse -Force
    }
}

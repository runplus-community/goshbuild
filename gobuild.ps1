param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $scriptDir "goshbuild.ps1"

if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "Missing goshbuild.ps1 next to gobuild.ps1"
}

& $target @RemainingArgs
exit $LASTEXITCODE

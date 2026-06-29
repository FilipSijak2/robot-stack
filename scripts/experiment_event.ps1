param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $EventArguments
)

if (-not $EventArguments) {
    Write-Error "Usage: .\scripts\experiment_event.ps1 <scenario> [start|end]"
    exit 2
}

& docker exec -i bag_recorder_cont python3 /app/experiment_event.py @EventArguments
exit $LASTEXITCODE

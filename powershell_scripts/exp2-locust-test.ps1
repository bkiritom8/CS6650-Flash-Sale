#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$REPO_ROOT   = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$LOCUST_FILE = Join-Path $REPO_ROOT "experiments\experiment2\locustfile.py"
$MAIN_TF     = Join-Path $REPO_ROOT "terraform\main"

# -- Tunable parameters --------------------------------------------------------
$USERS               = if ($env:USERS)               { $env:USERS }               else { "500" }
$SPAWN_RATE          = if ($env:SPAWN_RATE)          { $env:SPAWN_RATE }          else { "200" }
$RUN_TIME            = if ($env:RUN_TIME)            { $env:RUN_TIME }            else { "120s" }
$EVENT_ID            = if ($env:EVENT_ID)            { $env:EVENT_ID }            else { "evt-001" }
$BACKENDS            = if ($env:BACKENDS)            { $env:BACKENDS }            else { "mysql dynamodb" }
$QUEUE_POLL_INTERVAL = if ($env:QUEUE_POLL_INTERVAL) { [int]$env:QUEUE_POLL_INTERVAL } else { 5 }

# -- Directories ---------------------------------------------------------------
$CSV_DIR     = Join-Path $REPO_ROOT ".tmp\exp2_locust"
$LOG_DIR     = Join-Path $REPO_ROOT ".tmp\exp2_logs"
$RESULTS_DIR = Join-Path $REPO_ROOT "results"
New-Item -ItemType Directory -Force -Path $CSV_DIR, $LOG_DIR, $RESULTS_DIR | Out-Null

# -- Python detection ----------------------------------------------------------
$PY = $null
if     (Get-Command python  -ErrorAction SilentlyContinue) { $PY = "python"  }
elseif (Get-Command python3 -ErrorAction SilentlyContinue) { $PY = "python3" }
else   { Write-Host "ERROR: Python not found."; exit 1 }

# -- Locust detection ----------------------------------------------------------
if (-not (Get-Command locust -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: locust not found. Run: pip install locust"
    exit 1
}

# -- Get ALB URL from Terraform ------------------------------------------------
Set-Location $MAIN_TF
try {
    cmd /c "terraform output alb_dns_name" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    Write-Host ""
    Write-Host "ERROR: Platform is not deployed. Run: .\powershell_scripts\deploy.ps1"
    exit 1
}
$ALB         = (cmd /c "terraform output -raw alb_dns_name" 2>&1)
$BOOKING_URL = "http://$ALB"
Set-Location $REPO_ROOT

$PASS      = 0
$FAIL      = 0
$TIMESTAMP = Get-Date -Format "yyyyMMdd_HHmmss"
$SUMMARY_CSV = Join-Path $RESULTS_DIR "exp2_$TIMESTAMP.csv"

# -- Helpers -------------------------------------------------------------------
function ok   { param($msg) Write-Host "  [PASS] $msg"; $script:PASS++ }
function fail { param($msg) Write-Host "  [FAIL] $msg"; $script:FAIL++ }

# -- Reset DB between tests ----------------------------------------------------
function Reset-DB {
    Write-Host "    Resetting booking and inventory data..."
    try {
        Invoke-WebRequest -Uri "$script:BOOKING_URL/booking/api/v1/reset" `
            -Method POST -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null
    } catch { }
    Start-Sleep -Seconds 3
}

# -- Switch backend via Terraform ----------------------------------------------
function Switch-Backend {
    param([string]$backend)
    Write-Host "    Switching backend to: $backend..."
    Set-Location $script:MAIN_TF
    try {
        cmd /c "terraform apply -auto-approve -var=db_backend=$backend" 2>&1 | Out-Null
    } catch { }
    Set-Location $script:REPO_ROOT

    Write-Host -NoNewline "    Waiting for services to stabilise "
    $attempts = 0
    while ($true) {
        try {
            $r = Invoke-WebRequest -Uri "$script:BOOKING_URL/booking/health" -UseBasicParsing -ErrorAction Stop
            if ($r.StatusCode -eq 200) { break }
        } catch { }
        $attempts++
        if ($attempts -ge 20) {
            Write-Host ""
            Write-Host "ERROR: Health check timed out after switching to $backend"
            exit 1
        }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 10
    }
    Write-Host " ready"
}

# -- Poll queue metrics in background ------------------------------------------
# Called inside a Start-Job, writes one JSON line per poll until sentinel removed
$PollBlock = {
    param($bookingUrl, $eventId, $outFile, $sentinelFile, $interval)
    $snap = 0
    Set-Content -Path $outFile -Value ""
    while (Test-Path $sentinelFile) {
        try {
            $r      = Invoke-WebRequest -Uri "$bookingUrl/queue/api/v1/queue/event/$eventId/metrics" -UseBasicParsing -ErrorAction Stop
            $result = $r.Content
        } catch {
            $result = "{}"
        }
        Add-Content -Path $outFile -Value "{`"snapshot`":$snap,`"data`":$result}"
        $snap++
        Start-Sleep -Seconds $interval
    }
}

# -- Parse Locust CSV for summary stats ----------------------------------------
function Parse-LocustStats {
    param([string]$csvPrefix, [string]$endpointName)
    $statsFile = "${csvPrefix}_stats.csv"
    if (-not (Test-Path $statsFile)) { return "- - - - - -" }

    # Write python script to a temp file to avoid quote escaping issues
    $pyScript = @'
import sys, csv
path, name = sys.argv[1], sys.argv[2]
with open(path, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        if name in row.get("Name",""):
            avg   = round(float(row.get("Average Response Time", 0) or 0))
            p50   = row.get("50%",  "-") or "-"
            p95   = row.get("95%",  "-") or "-"
            p99   = row.get("99%",  "-") or "-"
            reqs  = row.get("Request Count",  "0") or "0"
            fails = row.get("Failure Count",  "0") or "0"
            print(avg, p50, p95, p99, reqs, fails)
            break
'@
    $tmpPy = Join-Path $script:CSV_DIR "parse_stats.py"
    Set-Content -Path $tmpPy -Value $pyScript -Encoding utf8
    try {
        $result = & $script:PY $tmpPy $statsFile $endpointName 2>$null
        if ($result) { return $result } else { return "- - - - - -" }
    } catch {
        return "- - - - - -"
    }
}

# -- Run one scenario ----------------------------------------------------------
function Run-Scenario {
    param(
        [string]$backend,
        [string]$scenario,
        [string]$userClass,
        [string]$csvSuffix,
        [string]$endpointName
    )
    $csvPrefix    = Join-Path $script:CSV_DIR "${backend}_${csvSuffix}"
    $logFile      = Join-Path $script:LOG_DIR  "${backend}_${csvSuffix}.log"
    $queueFile    = Join-Path $script:CSV_DIR  "${backend}_${csvSuffix}_queue_metrics.jsonl"
    $sentinelFile = Join-Path $script:CSV_DIR  "${backend}_${csvSuffix}.sentinel"

    Write-Host ""
    Write-Host "  Running: $backend / $scenario"

    # Start queue polling background job for queued scenario
    $pollJob = $null
    if ($scenario -eq "queued") {
        Set-Content -Path $sentinelFile -Value ""
        $pollJob = Start-Job -ScriptBlock $script:PollBlock `
            -ArgumentList $script:BOOKING_URL, $script:EVENT_ID, $queueFile, $sentinelFile, $script:QUEUE_POLL_INTERVAL
    }

    # Run Locust — wrap in try/catch so stderr output doesn't terminate the script
    try {
        cmd /c "locust -f `"$script:LOCUST_FILE`" $userClass --host $script:BOOKING_URL --headless --users $script:USERS --spawn-rate $script:SPAWN_RATE --run-time $script:RUN_TIME --csv `"$csvPrefix`" --loglevel WARNING" 2>&1 |
            Out-File -FilePath $logFile -Encoding utf8
    } catch { }

    # Stop queue polling
    if ($scenario -eq "queued") {
        Remove-Item -Path $sentinelFile -Force -ErrorAction SilentlyContinue
        if ($pollJob) { Wait-Job $pollJob | Out-Null; Remove-Job $pollJob }
        Write-Host "    Queue metrics saved to: $queueFile"
    }

    # Parse stats
    $stats  = Parse-LocustStats $csvPrefix $endpointName
    $parts  = $stats -split ' '
    $avg    = $parts[0]; $p50  = $parts[1]; $p95  = $parts[2]
    $p99    = $parts[3]; $reqs = $parts[4]; $fails = $parts[5]

    $successRate = "-"
    if ($reqs -ne "-" -and [int]$reqs -gt 0) {
        $successes   = [int]$reqs - [int]$fails
        $successRate = "$([math]::Round($successes / [int]$reqs * 100, 1))%"
    }

    Write-Host "    Requests : $reqs  Failures: $fails  Success: $successRate"
    Write-Host "    Latency  : avg=${avg}ms  p50=${p50}ms  p95=${p95}ms  p99=${p99}ms"

    # Append to summary CSV
    "$backend,$scenario,$reqs,$fails,$successRate,$avg,$p50,$p95,$p99,$queueFile" |
        Add-Content -Path $script:SUMMARY_CSV

    if ($fails -eq "0") { ok "$backend/$scenario - 0 failures" }
    else                { fail "$backend/$scenario - $fails failures out of $reqs requests" }
}

# -- Banner --------------------------------------------------------------------
Write-Host ""
Write-Host "=============================================================="
Write-Host "  Experiment 2 - Virtual Queue as Demand Buffer"
Write-Host "  Booking URL  : $BOOKING_URL"
Write-Host "  Backends     : $BACKENDS"
Write-Host "  Users        : $USERS  (set USERS=N to override)"
Write-Host "  Spawn rate   : $SPAWN_RATE/s  (set SPAWN_RATE=N to override)"
Write-Host "  Run time     : $RUN_TIME  (set RUN_TIME=Xs to override)"
Write-Host "  Event        : $EVENT_ID"
Write-Host "  Queue poll   : every ${QUEUE_POLL_INTERVAL}s during queued tests"
Write-Host "=============================================================="

# -- Health checks -------------------------------------------------------------
Write-Host ""
Write-Host "--- [1] Health checks"
foreach ($svc in @("inventory", "booking", "queue")) {
    try {
        $r    = Invoke-WebRequest -Uri "$BOOKING_URL/$svc/health" -UseBasicParsing -ErrorAction Stop
        $code = $r.StatusCode
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if (-not $code) { $code = 0 }
    }
    if ($code -eq 200) { ok "$svc-service /health (HTTP 200)" }
    else               { fail "$svc-service /health - expected 200, got $code" }
}

# -- Write CSV header ----------------------------------------------------------
"backend,scenario,requests,failures,success_rate,avg_ms,p50_ms,p95_ms,p99_ms,queue_metrics_file" |
    Set-Content -Path $SUMMARY_CSV

# -- Run all backend x scenario combinations -----------------------------------
$IDX = 2
foreach ($backend in ($BACKENDS -split ' ')) {
    Write-Host ""
    Write-Host "=============================================================="
    Write-Host "  Backend: $backend"
    Write-Host "=============================================================="

    Switch-Backend $backend

    Write-Host ""
    Write-Host "--- [$IDX] $backend / direct booking"
    Reset-DB
    Run-Scenario $backend "direct" "DirectBookingUser" "direct" "/booking/api/v1/bookings"
    $IDX++

    Write-Host ""
    Write-Host "--- [$IDX] $backend / queued booking"
    Reset-DB
    Run-Scenario $backend "queued" "QueuedBookingUser" "queued" "/booking/api/v1/bookings"
    $IDX++
}

# -- Summary -------------------------------------------------------------------
Write-Host ""
Write-Host "=============================================================="
Write-Host "  RESULTS SUMMARY"
Write-Host "=============================================================="
Write-Host ("  {0,-10} {1,-8} {2,8} {3,8} {4,10} {5,8} {6,7} {7,7} {8,7}" -f "Backend","Scenario","Requests","Failures","Success%","Avg(ms)","p50","p95","p99")
Write-Host ("  {0,-10} {1,-8} {2,8} {3,8} {4,10} {5,8} {6,7} {7,7} {8,7}" -f "-------","--------","--------","--------","---------","-------","---","---","---")

Get-Content $SUMMARY_CSV | Select-Object -Skip 1 | ForEach-Object {
    $c = $_ -split ','
    Write-Host ("  {0,-10} {1,-8} {2,8} {3,8} {4,10} {5,8} {6,7} {7,7} {8,7}" -f $c[0],$c[1],$c[2],$c[3],$c[4],$c[5],$c[6],$c[7],$c[8])
}

Write-Host ""
Write-Host "  Tests passed: $PASS  |  Tests failed: $FAIL"
Write-Host "=============================================================="
Write-Host ""
Write-Host "  Results CSV   : $SUMMARY_CSV"
Write-Host "  Locust logs   : $LOG_DIR\"
Write-Host "  Queue metrics : $CSV_DIR\*_queue_metrics.jsonl"
Write-Host ""

if ($FAIL -gt 0) {
    Write-Host "  Check logs for failures:"
    Write-Host "  aws logs tail /ecs/concert-platform-booking --follow --region us-east-1"
    exit 1
}

Write-Host "All experiment 2 tests passed."
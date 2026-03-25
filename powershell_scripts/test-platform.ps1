#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$ROOT_DIR = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location (Join-Path $ROOT_DIR "terraform\main")
$ALB = terraform output -raw alb_dns_name

$INV = "http://$ALB/inventory"
$BK  = "http://$ALB/booking"
$Q   = "http://$ALB/queue"

$PASS = 0
$FAIL = 0

# ── Helpers ───────────────────────────────────────────────────────────────────
function ok   { param($msg) Write-Host "  [PASS] $msg"; $script:PASS++ }
function fail { param($msg) Write-Host "  [FAIL] $msg"; $script:FAIL++ }

# Check HTTP status code only mirrors curl -s -o /dev/null -w "%{http_code}"
function Check-Endpoint {
    param(
        [string]$Label,
        [string]$Expected,
        [string]$Url,
        [string]$Method = "GET",
        [string]$Body   = ""
    )
    try {
        $params = @{
            Uri             = $Url
            Method          = $Method
            UseBasicParsing = $true
            ErrorAction     = "Stop"
        }
        if ($Body) {
            $params.Body        = $Body
            $params.ContentType = "application/json"
        }
        $resp   = Invoke-WebRequest @params
        $actual = $resp.StatusCode
    } catch {
        $actual = $_.Exception.Response.StatusCode.value__
        if (-not $actual) { $actual = 0 }
    }

    if ([string]$actual -eq $Expected) { ok "$Label (HTTP $actual)" }
    else { fail "$Label (expected $Expected, got $actual)" }
}

# Fetch JSON from a URL and return a value via a dot-notation key path
# e.g. Json-Get $url "total"  or  Json-Get $url "available_seats"
function Json-Get {
    param([string]$Url, [string]$Field)
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop
        $json = $resp.Content | ConvertFrom-Json
        return $json.$Field
    } catch {
        return $null
    }
}

# Fetch JSON and return an array field filtered/mapped inline via a scriptblock
function Json-Query {
    param([string]$Url, [scriptblock]$Query)
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop
        $json = $resp.Content | ConvertFrom-Json
        return & $Query $json
    } catch {
        return $null
    }
}

Write-Host ""
Write-Host "================================================"
Write-Host "  Concert Ticket Platform Smoke Tests"
Write-Host "  ALB : ${ALB} "
Write-Host "================================================"
Write-Host ""

# ── 1. Health checks ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- [1] Health Checks"
Check-Endpoint "inventory-service /health" "200" "$INV/health"
Check-Endpoint "booking-service /health"   "200" "$BK/health"
Check-Endpoint "queue-service /health"     "200" "$Q/health"

$lockMode = Json-Get "$BK/health" "lock_mode"
if ($lockMode) { ok "Lock mode active: $lockMode" }
else           { fail "Could not read lock_mode from booking health" }

# ── 2. Inventory service ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- [2] Inventory Service"

Check-Endpoint "GET /api/v1/events" "200" "$INV/api/v1/events"

$eventCount = Json-Get "$INV/api/v1/events" "total"
if ($eventCount -ge 5) { ok "Seed data present: $eventCount events" }
else                   { fail "Seed data missing - expected >=5 got $eventCount" }

$EVENT_ID = "evt-001"
Check-Endpoint "GET /api/v1/events/:id"              "200" "$INV/api/v1/events/$EVENT_ID"
Check-Endpoint "GET /api/v1/events/:id/availability" "200" "$INV/api/v1/events/$EVENT_ID/availability"
Check-Endpoint "GET /api/v1/events/:id/seats"        "200" "$INV/api/v1/events/$EVENT_ID/seats"

$avail = Json-Get "$INV/api/v1/events/$EVENT_ID/availability" "available_seats"
if ($avail -gt 0) { ok "evt-001 has $avail available seats" }
else              { fail "evt-001 has no available seats" }

# ── 3. Booking service ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- [3] Booking Service"

$seatId = Json-Query "$INV/api/v1/events/$EVENT_ID/seats" {
    param($json)
    $avail = $json.seats | Where-Object { $_.status -eq "available" }
    if ($avail) { return $avail[0].seat_id } else { return $null }
}

if (-not $seatId) {
    fail "No available seats for $EVENT_ID cannot test booking"}
else {
    Write-Host "    Using seat: $seatId"
    $bookingBody = '{"event_id":"' + $EVENT_ID + '","seat_id":"' + $seatId + '","customer_id":9001}'
    Check-Endpoint "POST /api/v1/bookings" "201" "$BK/api/v1/bookings" "POST" $bookingBody

    $bookingId = Json-Query "$BK/api/v1/events/$EVENT_ID/bookings" {
        param($json)
        $confirmed = $json.bookings | Where-Object { $_.status -eq "confirmed" }
        if ($confirmed) { return $confirmed[0].booking_id } else { return $null }
    }

    if ($bookingId) {
        ok "Booking confirmed, ID: $bookingId"
        Check-Endpoint "GET /api/v1/bookings/:id"          "200" "$BK/api/v1/bookings/$bookingId"
        Check-Endpoint "DELETE /api/v1/bookings/:id cancel" "200" "$BK/api/v1/bookings/$bookingId" "DELETE"
    } else {
        fail "Could not retrieve booking_id for event $EVENT_ID"
    }
}

Check-Endpoint "GET /api/v1/events/:id/bookings" "200" "$BK/api/v1/events/$EVENT_ID/bookings"
Check-Endpoint "GET /api/v1/metrics"             "200" "$BK/api/v1/metrics?event_id=$EVENT_ID"

$oversells = Json-Get "$BK/api/v1/metrics?event_id=$EVENT_ID" "oversell_count"
ok "Oversell count readable: $oversells"

# ── 4. Queue service ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- [4] Queue Service"

$joinBody = '{"event_id":"' + $EVENT_ID + '","customer_id":9001}'
Check-Endpoint "POST /api/v1/queue/join" "201" "$Q/api/v1/queue/join" "POST" $joinBody

$queueDepth = Json-Get "$Q/api/v1/queue/event/$EVENT_ID/metrics" "queue_depth"
if ($null -ne $queueDepth) { ok "Queue depth readable: $queueDepth" }
else                       { fail "Could not read queue depth" }

Check-Endpoint "GET /api/v1/queue/metrics"                 "200" "$Q/api/v1/queue/metrics"
Check-Endpoint "GET /api/v1/queue/event/:event_id/metrics" "200" "$Q/api/v1/queue/event/$EVENT_ID/metrics"

# ── 5. Runtime controls ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- [5] Runtime Controls"

Check-Endpoint "POST admission-rate (set to 20)" "200" `
    "$Q/api/v1/queue/event/$EVENT_ID/admission-rate" "POST" '{"rate":20}'

Check-Endpoint "POST fairness-mode (collapse)" "200" `
    "$Q/api/v1/queue/event/$EVENT_ID/fairness-mode" "POST" '{"mode":"collapse"}'

Check-Endpoint "POST fairness-mode (allow_multiple)" "200" `
    "$Q/api/v1/queue/event/$EVENT_ID/fairness-mode" "POST" '{"mode":"allow_multiple"}'

Check-Endpoint "POST admission-rate (reset to 10)" "200" `
    "$Q/api/v1/queue/event/$EVENT_ID/admission-rate" "POST" '{"rate":10}'

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================"
Write-Host "  Results: $PASS passed, $FAIL failed"
Write-Host "================================================"

if ($FAIL -gt 0) {
    Write-Host ""
    Write-Host "Check CloudWatch logs:"
    Write-Host "  aws logs tail /ecs/concert-platform-inventory --follow --region us-east-1"
    Write-Host "  aws logs tail /ecs/concert-platform-booking   --follow --region us-east-1"
    Write-Host "  aws logs tail /ecs/concert-platform-queue     --follow --region us-east-1"
    exit 1
}

Write-Host ""
Write-Host "Platform is fully operational."
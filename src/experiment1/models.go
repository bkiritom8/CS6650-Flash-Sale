package main

import "time"

// LockMode controls which concurrency strategy is tested.
//
//	none        → baseline: no control, oversells expected
//	optimistic  → read version → conditional update → retry on conflict
//	pessimistic → acquire row lock before checking (MySQL) / atomic txn (DynamoDB)
type LockMode string

const (
	LockNone        LockMode = "none"
	LockOptimistic  LockMode = "optimistic"
	LockPessimistic LockMode = "pessimistic"
)

// DBBackend selects the storage engine for the experiment.
type DBBackend string

const (
	BackendMySQL    DBBackend = "mysql"
	BackendDynamoDB DBBackend = "dynamodb"
)

// RunRequest configures a single experiment run.
type RunRequest struct {
	LockMode    LockMode  `json:"lock_mode"  binding:"required"`
	DBBackend   DBBackend `json:"db_backend" binding:"required"`
	Concurrency int       `json:"concurrency"` // defaults to 1000
	MaxRetries  int       `json:"max_retries"` // optimistic only, defaults to 3
}

// LatencyStats summarises per-attempt latency across all goroutines.
type LatencyStats struct {
	MinMS  float64 `json:"min_ms"`
	MaxMS  float64 `json:"max_ms"`
	MeanMS float64 `json:"mean_ms"`
	P99MS  float64 `json:"p99_ms"`
}

// ExperimentResult is the full output of one experiment run.
type ExperimentResult struct {
	RunID              string       `json:"run_id"`
	DBBackend          DBBackend    `json:"db_backend"`
	LockMode           LockMode     `json:"lock_mode"`
	Concurrency        int          `json:"concurrency"`
	SuccessfulBookings int          `json:"successful_bookings"`
	FailedBookings     int          `json:"failed_bookings"`
	OversellCount      int          `json:"oversell_count"`
	OversellRatePct    float64      `json:"oversell_rate_pct"`
	TotalDurationMS    float64      `json:"total_duration_ms"`
	Latency            LatencyStats `json:"latency_ms"`
	StartedAt          time.Time    `json:"started_at"`
	CompletedAt        time.Time    `json:"completed_at"`
}

type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}

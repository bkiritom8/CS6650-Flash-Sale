package main

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

// Runner executes one experiment run against a Repository.
// It spawns `concurrency` goroutines simultaneously (via a shared start channel)
// so all writers hit the DB at the same instant, maximising contention.
type Runner struct {
	mysqlRepo  Repository
	dynamoRepo Repository
}

func NewRunner(mysqlRepo, dynamoRepo Repository) *Runner {
	return &Runner{
		mysqlRepo:  mysqlRepo,
		dynamoRepo: dynamoRepo,
	}
}

// Run executes the experiment and returns the full result.
func (r *Runner) Run(ctx context.Context, req RunRequest) (*ExperimentResult, error) {
	repo, err := r.repoFor(req.DBBackend)
	if err != nil {
		return nil, err
	}

	concurrency := req.Concurrency
	if concurrency <= 0 {
		concurrency = 1000
	}
	maxRetries := req.MaxRetries
	if maxRetries <= 0 {
		maxRetries = 3
	}

	runID := uuid.New().String()
	// Unique event_id per run — prevents cross-run interference in the DB.
	eventID := fmt.Sprintf("exp1-%s", runID[:8])
	seatID := "seat-last"

	if err := repo.InitSeat(ctx, eventID, seatID); err != nil {
		return nil, fmt.Errorf("init seat: %w", err)
	}
	// Best-effort cleanup after the run regardless of outcome.
	defer repo.Cleanup(ctx, eventID, seatID)

	type outcome struct {
		latencyMS float64
		success   bool
	}

	results := make(chan outcome, concurrency)
	start := make(chan struct{}) // closed simultaneously to release all goroutines at once

	bookingIDs := make([]string, concurrency)
	for i := range bookingIDs {
		bookingIDs[i] = uuid.New().String()
	}

	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		bID := bookingIDs[i]
		go func(bookingID string) {
			defer wg.Done()
			<-start // block until all goroutines are ready

			t0 := time.Now()
			var callErr error

			switch req.LockMode {
			case LockNone:
				_, callErr = repo.BookNoLock(ctx, eventID, seatID, bookingID)
			case LockOptimistic:
				callErr = repo.BookOptimistic(ctx, eventID, seatID, bookingID, maxRetries)
			case LockPessimistic:
				callErr = repo.BookPessimistic(ctx, eventID, seatID, bookingID)
			}

			results <- outcome{
				latencyMS: float64(time.Since(t0).Microseconds()) / 1000.0,
				success:   callErr == nil,
			}
		}(bID)
	}

	startedAt := time.Now()
	close(start) // fire — all goroutines unblock simultaneously
	wg.Wait()
	completedAt := time.Now()
	close(results)

	// ── Aggregate outcomes ───────────────────────────────────────────────────
	var latencies []float64
	successCount := 0
	failCount := 0

	for o := range results {
		latencies = append(latencies, o.latencyMS)
		if o.success {
			successCount++
		} else {
			failCount++
		}
	}

	// ── Query DB for ground-truth oversell count ─────────────────────────────
	// Use a fresh context so connection pressure from the run doesn't cause
	// this metrics query to silently fail (error is discarded below).
	metricsCtx, metricsCancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer metricsCancel()
	oversellCount, _ := repo.CountOversells(metricsCtx, eventID, seatID)

	// ── Compute latency stats ────────────────────────────────────────────────
	stats := computeLatency(latencies)

	oversellRate := 0.0
	if concurrency > 0 {
		oversellRate = math.Round(float64(oversellCount)/float64(concurrency)*10000) / 100
	}

	return &ExperimentResult{
		RunID:              runID,
		DBBackend:          req.DBBackend,
		LockMode:           req.LockMode,
		Concurrency:        concurrency,
		SuccessfulBookings: successCount,
		FailedBookings:     failCount,
		OversellCount:      oversellCount,
		OversellRatePct:    oversellRate,
		TotalDurationMS:    float64(completedAt.Sub(startedAt).Milliseconds()),
		Latency:            stats,
		StartedAt:          startedAt,
		CompletedAt:        completedAt,
	}, nil
}

// ── Single-operation methods (used by Locust-facing HTTP endpoints) ───────────

func (r *Runner) InitSeat(ctx context.Context, dbBackend DBBackend, eventID, seatID string) error {
	repo, err := r.repoFor(dbBackend)
	if err != nil {
		return err
	}
	return repo.InitSeat(ctx, eventID, seatID)
}

// BookSingle processes one booking attempt from a Locust worker.
// got=true means this worker won the seat.
// got=false, err=nil means the seat was taken (expected for most workers).
// err!=nil means an actual infrastructure error.
func (r *Runner) BookSingle(ctx context.Context, req BookSeatRequest) (got bool, err error) {
	repo, err := r.repoFor(req.DBBackend)
	if err != nil {
		return false, err
	}
	maxRetries := req.MaxRetries
	if maxRetries <= 0 {
		maxRetries = 3
	}
	switch req.LockMode {
	case LockNone:
		_, err = repo.BookNoLock(ctx, req.EventID, req.SeatID, req.BookingID)
		return err == nil, err
	case LockOptimistic:
		err = repo.BookOptimistic(ctx, req.EventID, req.SeatID, req.BookingID, maxRetries)
		if isSeatUnavailable(err) {
			return false, nil
		}
		return err == nil, err
	case LockPessimistic:
		err = repo.BookPessimistic(ctx, req.EventID, req.SeatID, req.BookingID)
		if isSeatUnavailable(err) {
			return false, nil
		}
		return err == nil, err
	}
	return false, fmt.Errorf("unknown lock_mode %q", req.LockMode)
}

func (r *Runner) GetResults(ctx context.Context, dbBackend DBBackend, eventID, seatID string) (bookings, oversells int, err error) {
	repo, err := r.repoFor(dbBackend)
	if err != nil {
		return
	}
	bookings, err = repo.CountBookings(ctx, eventID, seatID)
	if err != nil {
		return
	}
	oversells, err = repo.CountOversells(ctx, eventID, seatID)
	return
}

func (r *Runner) CleanupSeat(ctx context.Context, dbBackend DBBackend, eventID, seatID string) error {
	repo, err := r.repoFor(dbBackend)
	if err != nil {
		return err
	}
	return repo.Cleanup(ctx, eventID, seatID)
}

func isSeatUnavailable(err error) bool {
	return err != nil && strings.Contains(err.Error(), "seat not available")
}

// ─────────────────────────────────────────────────────────────────────────────

func (r *Runner) repoFor(backend DBBackend) (Repository, error) {
	switch backend {
	case BackendMySQL:
		if r.mysqlRepo == nil {
			return nil, fmt.Errorf("MySQL backend not configured")
		}
		return r.mysqlRepo, nil
	case BackendDynamoDB:
		if r.dynamoRepo == nil {
			return nil, fmt.Errorf("DynamoDB backend not configured")
		}
		return r.dynamoRepo, nil
	default:
		return nil, fmt.Errorf("unknown db_backend %q, must be 'mysql' or 'dynamodb'", backend)
	}
}

// computeLatency returns min/max/mean/p99 from a slice of millisecond values.
func computeLatency(latencies []float64) LatencyStats {
	if len(latencies) == 0 {
		return LatencyStats{}
	}

	sort.Float64s(latencies)

	sum := 0.0
	for _, v := range latencies {
		sum += v
	}

	p99idx := int(math.Ceil(float64(len(latencies))*0.99)) - 1
	if p99idx < 0 {
		p99idx = 0
	}

	return LatencyStats{
		MinMS:  round2(latencies[0]),
		MaxMS:  round2(latencies[len(latencies)-1]),
		MeanMS: round2(sum / float64(len(latencies))),
		P99MS:  round2(latencies[p99idx]),
	}
}

func round2(v float64) float64 {
	return math.Round(v*100) / 100
}

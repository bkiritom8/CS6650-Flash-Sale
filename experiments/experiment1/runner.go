package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"sync"
	"time"

	"github.com/google/uuid"
)

// Runner calls the booking-service HTTP API.
// All locking logic lives in the booking service — experiment1 just drives it.
type Runner struct {
	bookingURL string
	client     *http.Client
}

func NewRunner(bookingURL string) *Runner {
	return &Runner{
		bookingURL: bookingURL,
		client:     &http.Client{Timeout: 30 * time.Second},
	}
}

// Run spawns concurrency goroutines that simultaneously POST to the booking service,
// maximising write contention — same as the Locust waiting-room pattern.
func (r *Runner) Run(ctx context.Context, req RunRequest) (*ExperimentResult, error) {
	concurrency := req.Concurrency
	if concurrency <= 0 {
		concurrency = 1000
	}
	maxRetries := req.MaxRetries
	if maxRetries <= 0 {
		maxRetries = 3
	}

	runID := uuid.New().String()
	eventID := fmt.Sprintf("exp1-%s", runID[:8])
	seatID := "seat-last"

	type outcome struct {
		latencyMS float64
		success   bool
	}

	results := make(chan outcome, concurrency)
	start := make(chan struct{})

	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start // wait until all goroutines are ready, then rush together

			t0 := time.Now()
			err := r.postBooking(ctx, eventID, seatID, req.LockMode, req.DBBackend, maxRetries)
			results <- outcome{
				latencyMS: float64(time.Since(t0).Microseconds()) / 1000.0,
				success:   err == nil,
			}
		}()
	}

	startedAt := time.Now()
	close(start)
	wg.Wait()
	completedAt := time.Now()
	close(results)

	var latencies []float64
	successCount, failCount := 0, 0
	for o := range results {
		latencies = append(latencies, o.latencyMS)
		if o.success {
			successCount++
		} else {
			failCount++
		}
	}

	metricsCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	bookings, oversells, _ := r.GetResults(metricsCtx, req.DBBackend, eventID, seatID)

	defer r.CleanupSeat(context.Background(), req.DBBackend, eventID, seatID)

	stats := computeLatency(latencies)
	oversellRate := 0.0
	if concurrency > 0 {
		oversellRate = math.Round(float64(oversells)/float64(concurrency)*10000) / 100
	}

	return &ExperimentResult{
		RunID:              runID,
		DBBackend:          req.DBBackend,
		LockMode:           req.LockMode,
		Concurrency:        concurrency,
		SuccessfulBookings: bookings,
		FailedBookings:     failCount,
		OversellCount:      oversells,
		OversellRatePct:    oversellRate,
		TotalDurationMS:    float64(completedAt.Sub(startedAt).Milliseconds()),
		Latency:            stats,
		StartedAt:          startedAt,
		CompletedAt:        completedAt,
	}, nil
}

// InitSeat is a no-op: the booking service auto-creates the seat_versions row on first
// write, and each run uses a fresh event_id so there is no prior state to reset.
func (r *Runner) InitSeat(_ context.Context, _ DBBackend, _, _ string) error {
	return nil
}

// BookSingle processes one booking attempt from a Locust worker.
func (r *Runner) BookSingle(ctx context.Context, req BookSeatRequest) (got bool, err error) {
	maxRetries := req.MaxRetries
	if maxRetries <= 0 {
		maxRetries = 3
	}
	err = r.postBooking(ctx, req.EventID, req.SeatID, req.LockMode, req.DBBackend, maxRetries)
	if err != nil {
		if err.Error() == "seat not available" {
			return false, nil // 409 — expected for all but one winner
		}
		return false, err
	}
	return true, nil
}

// GetResults fetches booking and oversell counts from the booking service.
func (r *Runner) GetResults(ctx context.Context, dbBackend DBBackend, eventID, seatID string) (bookings, oversells int, err error) {
	// Count confirmed bookings for this seat
	url := fmt.Sprintf("%s/api/v1/events/%s/bookings?db_backend=%s", r.bookingURL, eventID, dbBackend)
	resp, err := r.client.Get(url)
	if err != nil {
		return 0, 0, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	var listResp struct {
		Bookings []struct {
			SeatID string `json:"seat_id"`
			Status string `json:"status"`
		} `json:"bookings"`
	}
	if json.Unmarshal(body, &listResp) == nil {
		for _, b := range listResp.Bookings {
			if b.SeatID == seatID && b.Status == "confirmed" {
				bookings++
			}
		}
	}

	// Get oversell count from metrics endpoint
	mURL := fmt.Sprintf("%s/api/v1/metrics?event_id=%s&db_backend=%s", r.bookingURL, eventID, dbBackend)
	resp2, err := r.client.Get(mURL)
	if err != nil {
		return bookings, 0, nil
	}
	defer resp2.Body.Close()
	body2, _ := io.ReadAll(resp2.Body)
	var mResp struct {
		OversellCount int `json:"oversell_count"`
	}
	json.Unmarshal(body2, &mResp)
	return bookings, mResp.OversellCount, nil
}

// CleanupSeat removes all bookings for the test event via the booking service.
func (r *Runner) CleanupSeat(ctx context.Context, dbBackend DBBackend, eventID, _ string) error {
	req, _ := http.NewRequestWithContext(ctx, http.MethodDelete,
		fmt.Sprintf("%s/api/v1/internal/events/%s/data?db_backend=%s", r.bookingURL, eventID, dbBackend),
		nil)
	resp, err := r.client.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

// postBooking calls POST /booking/api/v1/bookings with per-request lock_mode and db_backend.
func (r *Runner) postBooking(ctx context.Context, eventID, seatID string, lockMode LockMode, dbBackend DBBackend, maxRetries int) error {
	payload, _ := json.Marshal(map[string]interface{}{
		"event_id":    eventID,
		"seat_id":     seatID,
		"customer_id": 1,
		"lock_mode":   string(lockMode),
		"db_backend":  string(dbBackend),
		"max_retries": maxRetries,
	})

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/api/v1/bookings", r.bookingURL),
		bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := r.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	switch resp.StatusCode {
	case http.StatusCreated:
		return nil
	case http.StatusConflict:
		return fmt.Errorf("seat not available")
	default:
		return fmt.Errorf("booking service returned %d", resp.StatusCode)
	}
}

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

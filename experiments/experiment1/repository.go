package main

import "context"

// Repository is the storage interface for Experiment 1.
// MySQL and DynamoDB both implement it.
// Each method maps directly to one of the three concurrency strategies being tested.
type Repository interface {
	// InitSeat creates a fresh "available" seat record for one run.
	// Called once before spawning goroutines.
	InitSeat(ctx context.Context, eventID, seatID string) error

	// BookNoLock checks availability then writes without holding any lock.
	// Intentionally racy — the baseline that demonstrates oversells.
	// Returns oversold=true when the seat was already taken at read time.
	BookNoLock(ctx context.Context, eventID, seatID, bookingID string) (oversold bool, err error)

	// BookOptimistic reads the current version, then does a conditional update.
	// Retries up to maxRetries on version conflict. Prevents oversells without locking.
	BookOptimistic(ctx context.Context, eventID, seatID, bookingID string, maxRetries int) error

	// BookPessimistic acquires a row-level lock (MySQL: SELECT FOR UPDATE;
	// DynamoDB: TransactWriteItems) before checking availability.
	// Serialises all writers — zero oversells, higher latency.
	BookPessimistic(ctx context.Context, eventID, seatID, bookingID string) error

	// CountBookings returns the total number of bookings written for this seat.
	// In no-lock mode this will exceed 1 — that's the oversell evidence.
	CountBookings(ctx context.Context, eventID, seatID string) (int, error)

	// CountOversells returns how many oversell events were recorded.
	CountOversells(ctx context.Context, eventID, seatID string) (int, error)

	// Cleanup removes all rows created for this run so runs stay independent.
	Cleanup(ctx context.Context, eventID, seatID string) error

	Close() error
}

package main

import "time"

// LockMode controls concurrency strategy — set via LOCK_MODE env var.
// Teammates switch this per experiment without touching any Go code.
//
//	none        → Experiment 1 baseline  (no concurrency control, oversells expected)
//	optimistic  → Experiment 1 variant A (version-check before commit, retry on conflict)
//	pessimistic → Experiment 1 variant B (row-level lock, serialised access)  ← default
type LockMode string

const (
	LockNone        LockMode = "none"
	LockOptimistic  LockMode = "optimistic"
	LockPessimistic LockMode = "pessimistic"
)

type Booking struct {
	BookingID  string    `json:"booking_id"`
	EventID    string    `json:"event_id"`
	SeatID     string    `json:"seat_id"`
	CustomerID int       `json:"customer_id"`
	Status     string    `json:"status"` // confirmed, failed, cancelled
	LockMode   string    `json:"lock_mode"`
	CreatedAt  time.Time `json:"created_at"`
}

type CreateBookingRequest struct {
	EventID    string `json:"event_id"    binding:"required"`
	SeatID     string `json:"seat_id"     binding:"required"`
	CustomerID int    `json:"customer_id" binding:"required"`
	// Per-request overrides — used by experiment1 to test all combinations
	// without redeploying. Falls back to service-level config if omitted.
	LockMode   string `json:"lock_mode,omitempty"`
	DBBackend  string `json:"db_backend,omitempty"`
	MaxRetries int    `json:"max_retries,omitempty"`
}

type BookingResponse struct {
	Booking    *Booking `json:"booking"`
	OversoldBy int      `json:"oversold_by,omitempty"` // >0 only in no-lock mode
}

type ListBookingsResponse struct {
	Bookings []Booking `json:"bookings"`
	Total    int       `json:"total"`
}

type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}

// OversellEvent is recorded whenever a seat is double-booked (no-lock mode).
// The dashboard reads /api/v1/metrics to get the running count.
type OversellEvent struct {
	EventID   string    `json:"event_id"`
	SeatID    string    `json:"seat_id"`
	At        time.Time `json:"at"`
}
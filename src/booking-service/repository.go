package main

import "context"

// Repository is the storage interface for bookings.
// MySQL and DynamoDB both implement this.
// The locking strategy is injected at the call site, not inside the repo,
// so teammates can observe identical DB behaviour under different modes.
type Repository interface {
	// CreateBooking persists a new booking record.
	CreateBooking(ctx context.Context, b *Booking) error

	// GetBooking retrieves a single booking by ID.
	GetBooking(ctx context.Context, bookingID string) (*Booking, error)

	// ListBookingsByEvent returns all bookings for an event.
	ListBookingsByEvent(ctx context.Context, eventID string) ([]Booking, error)

	// CancelBooking marks a booking as cancelled.
	CancelBooking(ctx context.Context, bookingID string) error

	// CheckAndReserveNoLock attempts to book without any concurrency control.
	// Used in LockNone mode — deliberately unsafe, for Experiment 1 baseline.
	CheckAndReserveNoLock(ctx context.Context, eventID, seatID string, b *Booking) error

	// CheckAndReserveOptimistic reads current version, writes only if version unchanged.
	// Retries up to maxRetries on conflict.
	CheckAndReserveOptimistic(ctx context.Context, eventID, seatID string, b *Booking, maxRetries int) error

	// CheckAndReservePessimistic acquires a row-level lock before checking availability.
	// Serialises access — correctness guaranteed, higher latency.
	CheckAndReservePessimistic(ctx context.Context, eventID, seatID string, b *Booking) error

	// CountOversells returns the number of oversell events for an event.
	CountOversells(ctx context.Context, eventID string) (int, error)

	// ResetBookings drops all booking data — used between experiment runs.
	ResetBookings(ctx context.Context) error

	Close() error
}
package main

import "context"

// Repository is the storage interface for inventory.
// Both MySQL and DynamoDB implement this — swap via DB_BACKEND env var.
type Repository interface {
	// Events
	ListEvents(ctx context.Context) ([]Event, error)
	GetEvent(ctx context.Context, eventID string) (*Event, error)

	// Seats
	ListSeats(ctx context.Context, eventID string) ([]Seat, error)
	GetAvailableCount(ctx context.Context, eventID string) (int, error)

	// Called by booking-service via internal HTTP to reserve/release
	ReserveSeat(ctx context.Context, eventID, seatID string) error
	ReleaseSeat(ctx context.Context, eventID, seatID string) error

	// Seed — called once at startup
	SeedData(ctx context.Context) error

	// Cleanup method for testing — drops all data and recreates tables.
	ResetInventory(ctx context.Context) error

	Close() error
}

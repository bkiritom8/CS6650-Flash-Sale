package main

import "time"

type Event struct {
	EventID     string    `json:"event_id"`
	Name        string    `json:"name"`
	Venue       string    `json:"venue"`
	Date        string    `json:"date"`
	TotalSeats  int       `json:"total_seats"`
	Available   int       `json:"available_seats"`
	Price       float64   `json:"price"`
	CreatedAt   time.Time `json:"created_at"`
}

type Seat struct {
	SeatID    string    `json:"seat_id"`
	EventID   string    `json:"event_id"`
	SeatNo    string    `json:"seat_no"`
	Status    string    `json:"status"` // available, reserved, booked
	CreatedAt time.Time `json:"created_at"`
}

type ListEventsResponse struct {
	Events []Event `json:"events"`
	Total  int     `json:"total"`
}

type ListSeatsResponse struct {
	EventID string `json:"event_id"`
	Seats   []Seat `json:"seats"`
	Total   int    `json:"total"`
}

type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}

// Seed data — 5 events with varying seat counts to cover all experiment scenarios
var seedEvents = []struct {
	id         string
	name       string
	venue      string
	date       string
	totalSeats int
	price      float64
}{
	{"evt-001", "Taylor Swift - Eras Tour", "Madison Square Garden", "2025-06-15", 1000, 299.99},
	{"evt-002", "Coldplay - Music of the Spheres", "Fenway Park", "2025-07-04", 500, 199.99},
	{"evt-003", "The Weeknd - After Hours", "TD Garden", "2025-07-20", 200, 249.99},
	{"evt-004", "Billie Eilish - Hit Me Hard", "House of Blues", "2025-08-01", 100, 149.99},
	{"evt-005", "Drake - It's All a Blur", "Gillette Stadium", "2025-08-15", 2000, 179.99},
}
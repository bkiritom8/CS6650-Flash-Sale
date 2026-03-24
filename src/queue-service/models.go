package main

import "time"

// QueueEntry represents one user's position in the virtual waiting room.
type QueueEntry struct {
	QueueID    string    `json:"queue_id"`
	EventID    string    `json:"event_id"`
	CustomerID int       `json:"customer_id"`
	Position   int       `json:"position"`
	Status     string    `json:"status"` // waiting, admitted, expired
	IP         string    `json:"ip,omitempty"`
	JoinedAt   time.Time `json:"joined_at"`
	AdmittedAt *time.Time `json:"admitted_at,omitempty"`
}

type JoinQueueRequest struct {
	EventID    string `json:"event_id"    binding:"required"`
	CustomerID int    `json:"customer_id" binding:"required"`
}

type QueueStatusResponse struct {
	QueueID         string `json:"queue_id"`
	EventID         string `json:"event_id"`
	Position        int    `json:"position"`
	Status          string `json:"status"`
	AheadOfYou      int    `json:"ahead_of_you"`
	EstimatedWaitMs int64  `json:"estimated_wait_ms"`
}

type QueueMetrics struct {
	EventID          string `json:"event_id"`
	Depth            int    `json:"queue_depth"`
	AdmissionRateHz  int    `json:"admission_rate_hz"` // admissions per second
	TotalAdmitted    int64  `json:"total_admitted"`
	TotalWaiting     int    `json:"total_waiting"`
	// FairnessMode controls Experiment 5 behaviour:
	//   "collapse" → one queue slot per IP (fairer to others)
	//   "allow_multiple" → multiple slots per IP (higher throughput)
	FairnessMode     string `json:"fairness_mode"`
}

type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}
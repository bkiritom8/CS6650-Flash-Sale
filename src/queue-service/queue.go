package main

import (
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
)

// FairnessMode controls Experiment 5 policy.
// Switchable at runtime via FAIRNESS_MODE env var.
//
//	collapse        → one queue slot per IP (fairer, harder to game)
//	allow_multiple  → multiple slots per IP (higher throughput, less fair)
type FairnessMode string

const (
	FairnessCollapse       FairnessMode = "collapse"
	FairnessAllowMultiple  FairnessMode = "allow_multiple"
)

// VirtualQueue manages the in-memory waiting room for a single event.
// Experiment 2: demonstrates demand buffering vs direct booking-service load.
// Experiment 3: admission rate controls throughput into booking-service.
// Experiment 5: fairness mode controls per-IP policy.
type VirtualQueue struct {
	mu            sync.Mutex
	eventID       string
	entries       []*QueueEntry          // ordered FIFO
	byID          map[string]*QueueEntry // fast lookup by queue_id
	byIP          map[string]string      // IP → queue_id (for collapse mode)
	admissionRate int                    // admissions per second
	fairnessMode  FairnessMode
	totalAdmitted atomic.Int64
	stop          chan struct{}
}

func NewVirtualQueue(eventID string, admissionRate int, mode FairnessMode) *VirtualQueue {
	q := &VirtualQueue{
		eventID:       eventID,
		entries:       make([]*QueueEntry, 0, 64),
		byID:          make(map[string]*QueueEntry),
		byIP:          make(map[string]string),
		admissionRate: admissionRate,
		fairnessMode:  mode,
		stop:          make(chan struct{}),
	}
	go q.admissionLoop()
	return q
}

// Join adds a user to the queue. Returns the QueueEntry with position assigned.
// In collapse mode, a second join from the same IP returns the existing entry.
func (q *VirtualQueue) Join(customerID int, ip string) (*QueueEntry, error) {
	q.mu.Lock()
	defer q.mu.Unlock()

	// Experiment 5 — collapse mode: reuse existing slot for this IP
	if q.fairnessMode == FairnessCollapse {
		if existingID, ok := q.byIP[ip]; ok {
			if e, ok := q.byID[existingID]; ok && e.Status == "waiting" {
				return e, nil
			}
		}
	}

	entry := &QueueEntry{
		QueueID:    uuid.New().String(),
		EventID:    q.eventID,
		CustomerID: customerID,
		Position:   len(q.entries) + 1,
		Status:     "waiting",
		IP:         ip,
		JoinedAt:   time.Now().UTC(),
	}

	q.entries = append(q.entries, entry)
	q.byID[entry.QueueID] = entry
	if q.fairnessMode == FairnessCollapse {
		q.byIP[ip] = entry.QueueID
	}

	return entry, nil
}

// Status returns current position and estimated wait for a queue entry.
func (q *VirtualQueue) Status(queueID string) (*QueueStatusResponse, error) {
	q.mu.Lock()
	defer q.mu.Unlock()

	e, ok := q.byID[queueID]
	if !ok {
		return nil, fmt.Errorf("queue entry not found: %s", queueID)
	}

	ahead := 0
	for _, entry := range q.entries {
		if entry.Status == "waiting" && entry.JoinedAt.Before(e.JoinedAt) {
			ahead++
		}
	}

	var estimatedWaitMs int64
	if q.admissionRate > 0 {
		estimatedWaitMs = int64(ahead) * 1000 / int64(q.admissionRate)
	}

	return &QueueStatusResponse{
		QueueID:         e.QueueID,
		EventID:         e.EventID,
		Position:        e.Position,
		Status:          e.Status,
		AheadOfYou:      ahead,
		EstimatedWaitMs: estimatedWaitMs,
	}, nil
}

// Metrics returns current queue state for the dashboard.
func (q *VirtualQueue) Metrics() QueueMetrics {
	q.mu.Lock()
	defer q.mu.Unlock()

	waiting := 0
	for _, e := range q.entries {
		if e.Status == "waiting" {
			waiting++
		}
	}

	return QueueMetrics{
		EventID:         q.eventID,
		Depth:           waiting,
		AdmissionRateHz: q.admissionRate,
		TotalAdmitted:   q.totalAdmitted.Load(),
		TotalWaiting:    waiting,
		FairnessMode:    string(q.fairnessMode),
	}
}

// SetAdmissionRate allows teammates to change rate at runtime for Experiment 3.
func (q *VirtualQueue) SetAdmissionRate(rate int) {
	q.mu.Lock()
	q.admissionRate = rate
	q.mu.Unlock()
}

// SetFairnessMode allows teammates to switch mode at runtime for Experiment 5.
func (q *VirtualQueue) SetFairnessMode(mode FairnessMode) {
	q.mu.Lock()
	q.fairnessMode = mode
	q.byIP = make(map[string]string) // reset IP map on mode change
	q.mu.Unlock()
}

// Stop shuts down the admission loop cleanly.
func (q *VirtualQueue) Stop() {
	close(q.stop)
}

// admissionLoop runs in the background and admits users at the configured rate.
// This is the core of Experiment 2 — it acts as the demand buffer between
// the public internet and the booking-service.
func (q *VirtualQueue) admissionLoop() {
	for {
		select {
		case <-q.stop:
			return
		default:
		}

		rate := q.getAdmissionRate()
		if rate <= 0 {
			time.Sleep(100 * time.Millisecond)
			continue
		}

		interval := time.Second / time.Duration(rate)
		time.Sleep(interval)

		q.mu.Lock()
		for _, e := range q.entries {
			if e.Status == "waiting" {
				now := time.Now().UTC()
				e.Status = "admitted"
				e.AdmittedAt = &now
				q.totalAdmitted.Add(1)
				log.Printf("admitted queue_id=%s event=%s customer=%d",
					e.QueueID, e.EventID, e.CustomerID)
				break
			}
		}
		q.mu.Unlock()
	}
}

func (q *VirtualQueue) getAdmissionRate() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.admissionRate
}

// QueueManager manages one VirtualQueue per event.
type QueueManager struct {
	mu            sync.RWMutex
	queues        map[string]*VirtualQueue
	admissionRate int
	fairnessMode  FairnessMode
}

func NewQueueManager(admissionRate int, mode FairnessMode) *QueueManager {
	return &QueueManager{
		queues:        make(map[string]*VirtualQueue),
		admissionRate: admissionRate,
		fairnessMode:  mode,
	}
}

func (m *QueueManager) GetOrCreate(eventID string) *VirtualQueue {
	m.mu.Lock()
	defer m.mu.Unlock()

	if q, ok := m.queues[eventID]; ok {
		return q
	}
	q := NewVirtualQueue(eventID, m.admissionRate, m.fairnessMode)
	m.queues[eventID] = q
	log.Printf("created queue for event=%s rate=%d mode=%s",
		eventID, m.admissionRate, m.fairnessMode)
	return q
}

func (m *QueueManager) AllMetrics() []QueueMetrics {
	m.mu.RLock()
	defer m.mu.RUnlock()

	metrics := make([]QueueMetrics, 0, len(m.queues))
	for _, q := range m.queues {
		metrics = append(metrics, q.Metrics())
	}
	return metrics
}

func (m *QueueManager) StopAll() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, q := range m.queues {
		q.Stop()
	}
}
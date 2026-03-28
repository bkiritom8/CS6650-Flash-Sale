package main

import (
	"fmt"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type Handler struct {
	mysqlRepo      Repository
	dynamoRepo     Repository
	defaultBackend string
	lockMode       LockMode
	inventoryURL   string
	bookingsPerSec atomic.Int64
	httpClient     *http.Client
}

func NewHandler(mysqlRepo, dynamoRepo Repository, defaultBackend string, lockMode LockMode, inventoryURL string) *Handler {
	return &Handler{
		mysqlRepo:      mysqlRepo,
		dynamoRepo:     dynamoRepo,
		defaultBackend: defaultBackend,
		lockMode:       lockMode,
		inventoryURL:   inventoryURL,
		httpClient:     &http.Client{Timeout: 5 * time.Second},
	}
}

func (h *Handler) RegisterRoutes(r *gin.Engine) {
	r.GET("/health", h.Health)
	r.GET("/booking/health", h.Health)

	for _, base := range []string{"", "/booking"} {
		g := r.Group(base + "/api/v1")
		g.POST("/bookings", h.CreateBooking)
		g.GET("/bookings/:booking_id", h.GetBooking)
		g.GET("/events/:event_id/bookings", h.ListBookings)
		g.DELETE("/bookings/:booking_id", h.CancelBooking)
		g.GET("/metrics", h.GetMetrics)

		internal := g.Group("/internal")
		internal.POST("/events/:event_id/seats/:seat_id/reserve", h.ReserveSeat)
		internal.POST("/events/:event_id/seats/:seat_id/release", h.ReleaseSeat)
		internal.DELETE("/events/:event_id/data", h.CleanupEventData)
	}
}

func (h *Handler) Health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status":    "healthy",
		"service":   "booking-service",
		"lock_mode": string(h.lockMode),
	})
}

func (h *Handler) CreateBooking(c *gin.Context) {
	var req CreateBookingRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{"INVALID_INPUT", err.Error()})
		return
	}

	repo, err := h.repoFor(req.DBBackend)
	if err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{"INVALID_BACKEND", err.Error()})
		return
	}

	effectiveLockMode := h.lockMode
	if req.LockMode != "" {
		effectiveLockMode = LockMode(req.LockMode)
	}

	maxRetries := req.MaxRetries
	if maxRetries <= 0 {
		maxRetries = 3
	}

	b := &Booking{
		BookingID:  uuid.New().String(),
		EventID:    req.EventID,
		SeatID:     req.SeatID,
		CustomerID: req.CustomerID,
		Status:     "confirmed",
		LockMode:   string(effectiveLockMode),
		CreatedAt:  time.Now().UTC(),
	}

	var bookingErr error
	switch effectiveLockMode {
	case LockNone:
		bookingErr = repo.CheckAndReserveNoLock(c.Request.Context(), req.EventID, req.SeatID, b)
	case LockOptimistic:
		bookingErr = repo.CheckAndReserveOptimistic(c.Request.Context(), req.EventID, req.SeatID, b, maxRetries)
	case LockPessimistic:
		bookingErr = repo.CheckAndReservePessimistic(c.Request.Context(), req.EventID, req.SeatID, b)
	default:
		c.JSON(http.StatusInternalServerError, ErrorResponse{"CONFIG_ERROR",
			fmt.Sprintf("unknown lock mode: %s", effectiveLockMode)})
		return
	}

	if bookingErr != nil {
		b.Status = "failed"
		c.JSON(http.StatusConflict, ErrorResponse{"BOOKING_FAILED", bookingErr.Error()})
		return
	}

	h.bookingsPerSec.Add(1)
	go h.notifyInventoryReserve(req.EventID, req.SeatID)
	c.JSON(http.StatusCreated, BookingResponse{Booking: b})
}

func (h *Handler) GetBooking(c *gin.Context) {
	repo, err := h.repoFor("")
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"DB_ERROR", err.Error()})
		return
	}
	b, err := repo.GetBooking(c.Request.Context(), c.Param("booking_id"))
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"DB_ERROR", err.Error()})
		return
	}
	if b == nil {
		c.JSON(http.StatusNotFound, ErrorResponse{"NOT_FOUND", "booking not found"})
		return
	}
	c.JSON(http.StatusOK, b)
}

func (h *Handler) ListBookings(c *gin.Context) {
	repo, err := h.repoFor(c.Query("db_backend"))
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"DB_ERROR", err.Error()})
		return
	}
	bookings, err := repo.ListBookingsByEvent(c.Request.Context(), c.Param("event_id"))
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"DB_ERROR", err.Error()})
		return
	}
	if bookings == nil {
		bookings = []Booking{}
	}
	c.JSON(http.StatusOK, ListBookingsResponse{Bookings: bookings, Total: len(bookings)})
}

func (h *Handler) CancelBooking(c *gin.Context) {
	repo, err := h.repoFor("")
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"DB_ERROR", err.Error()})
		return
	}
	if err := repo.CancelBooking(c.Request.Context(), c.Param("booking_id")); err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"DB_ERROR", err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "cancelled"})
}

func (h *Handler) GetMetrics(c *gin.Context) {
	eventID := c.Query("event_id")
	repo, err := h.repoFor(c.Query("db_backend"))
	if err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{"INVALID_BACKEND", err.Error()})
		return
	}
	oversells := 0
	if eventID != "" {
		oversells, _ = repo.CountOversells(c.Request.Context(), eventID)
	}
	c.JSON(http.StatusOK, gin.H{
		"lock_mode":        string(h.lockMode),
		"bookings_per_sec": h.bookingsPerSec.Load(),
		"oversell_count":   oversells,
	})
}

// CleanupEventData deletes all test data for an event — used by experiment1 after each run.
func (h *Handler) CleanupEventData(c *gin.Context) {
	eventID := c.Param("event_id")
	repo, err := h.repoFor(c.Query("db_backend"))
	if err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{"INVALID_BACKEND", err.Error()})
		return
	}
	bookings, err := repo.ListBookingsByEvent(c.Request.Context(), eventID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"DB_ERROR", err.Error()})
		return
	}
	for _, b := range bookings {
		_ = repo.CancelBooking(c.Request.Context(), b.BookingID)
	}
	c.JSON(http.StatusOK, gin.H{"cleaned": len(bookings)})
}

func (h *Handler) ReserveSeat(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"event_id": c.Param("event_id"),
		"seat_id":  c.Param("seat_id"),
		"status":   "reserved",
	})
}

func (h *Handler) ReleaseSeat(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"event_id": c.Param("event_id"),
		"seat_id":  c.Param("seat_id"),
		"status":   "available",
	})
}

func (h *Handler) notifyInventoryReserve(eventID, seatID string) {
	url := fmt.Sprintf("%s/api/v1/internal/events/%s/seats/%s/reserve",
		h.inventoryURL, eventID, seatID)
	req, err := http.NewRequest(http.MethodPost, url, nil)
	if err != nil {
		return
	}
	resp, err := h.httpClient.Do(req)
	if err != nil || resp == nil {
		return
	}
	defer resp.Body.Close()
}

// repoFor returns the repo for the given backend string (empty = use default).
func (h *Handler) repoFor(dbBackend string) (Repository, error) {
	if dbBackend == "" {
		dbBackend = h.defaultBackend
	}
	switch dbBackend {
	case "mysql":
		if h.mysqlRepo == nil {
			return nil, fmt.Errorf("MySQL backend not configured")
		}
		return h.mysqlRepo, nil
	case "dynamodb":
		if h.dynamoRepo == nil {
			return nil, fmt.Errorf("DynamoDB backend not configured")
		}
		return h.dynamoRepo, nil
	default:
		return nil, fmt.Errorf("unknown db_backend %q", dbBackend)
	}
}

package main

import (
	"fmt"
	"log"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type Handler struct {
	repo           Repository
	lockMode       LockMode
	inventoryURL   string
	bookingsPerSec atomic.Int64
	httpClient     *http.Client
}

func NewHandler(repo Repository, lockMode LockMode, inventoryURL string) *Handler {
	return &Handler{
		repo:         repo,
		lockMode:     lockMode,
		inventoryURL: inventoryURL,
		httpClient:   &http.Client{Timeout: 5 * time.Second},
	}
}

func (h *Handler) RegisterRoutes(r *gin.Engine) {
	// Health check — both bare and ALB-prefixed
	r.GET("/health", h.Health)
	r.GET("/booking/health", h.Health)

	for _, base := range []string{"", "/booking"} {
		g := r.Group(base + "/api/v1")
		g.POST("/bookings", h.CreateBooking)
		g.GET("/bookings/:booking_id", h.GetBooking)
		g.GET("/events/:event_id/bookings", h.ListBookings)
		g.DELETE("/bookings/:booking_id", h.CancelBooking)
		g.GET("/metrics", h.GetMetrics)
		// For testing/demo purposes, an endpoint to reset all booking data (also calls inventory reset to keep in sync)
		g.POST("/reset", h.resetBookings)
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

	b := &Booking{
		BookingID:  uuid.New().String(),
		EventID:    req.EventID,
		SeatID:     req.SeatID,
		CustomerID: req.CustomerID,
		Status:     "confirmed",
		LockMode:   string(h.lockMode),
		CreatedAt:  time.Now().UTC(),
	}

	var err error
	switch h.lockMode {
	case LockNone:
		err = h.repo.CheckAndReserveNoLock(c.Request.Context(), req.EventID, req.SeatID, b)
	case LockOptimistic:
		err = h.repo.CheckAndReserveOptimistic(c.Request.Context(), req.EventID, req.SeatID, b, 3)
	case LockPessimistic:
		err = h.repo.CheckAndReservePessimistic(c.Request.Context(), req.EventID, req.SeatID, b)
	default:
		c.JSON(http.StatusInternalServerError, ErrorResponse{"CONFIG_ERROR",
			fmt.Sprintf("unknown lock mode: %s", h.lockMode)})
		return
	}

	if err != nil {
		b.Status = "failed"
		c.JSON(http.StatusConflict, ErrorResponse{"BOOKING_FAILED", err.Error()})
		return
	}

	h.bookingsPerSec.Add(1)
	go h.notifyInventoryReserve(req.EventID, req.SeatID)

	c.JSON(http.StatusCreated, BookingResponse{Booking: b})
}

func (h *Handler) GetBooking(c *gin.Context) {
	b, err := h.repo.GetBooking(c.Request.Context(), c.Param("booking_id"))
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
	bookings, err := h.repo.ListBookingsByEvent(c.Request.Context(), c.Param("event_id"))
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
	if err := h.repo.CancelBooking(c.Request.Context(), c.Param("booking_id")); err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"DB_ERROR", err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "cancelled"})
}

func (h *Handler) GetMetrics(c *gin.Context) {
	eventID := c.Query("event_id")
	oversells := 0
	if eventID != "" {
		oversells, _ = h.repo.CountOversells(c.Request.Context(), eventID)
	}
	c.JSON(http.StatusOK, gin.H{
		"lock_mode":        string(h.lockMode),
		"bookings_per_sec": h.bookingsPerSec.Load(),
		"oversell_count":   oversells,
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

func (h *Handler) resetBookings(c *gin.Context) {
	if err := h.repo.ResetBookings(c.Request.Context()); err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"RESET_FAILED", err.Error()})
		return
	}
	log.Println("Booking data reset successfully")

	// Also reset inventory to keep in sync
	url := fmt.Sprintf("%s/api/v1/internal/events/reset", h.inventoryURL)
	req, err := http.NewRequest(http.MethodPost, url, nil)
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"RESET_FAILED", err.Error()})
		return
	}
	resp, err := h.httpClient.Do(req)
	if err != nil || resp == nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"RESET_FAILED", err.Error()})
		return
	}
	defer resp.Body.Close()
}

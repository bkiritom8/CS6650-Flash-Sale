package main

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

type Handler struct {
	runner *Runner
}

func NewHandler(runner *Runner) *Handler {
	return &Handler{runner: runner}
}

func (h *Handler) RegisterRoutes(r *gin.Engine) {
	r.GET("/health", h.Health)
	r.GET("/experiment1/health", h.Health)

	for _, base := range []string{"", "/experiment1"} {
		g := r.Group(base + "/api/v1")
		// Legacy batch runner (kept for backward compat)
		g.POST("/run", h.RunExperiment)
		// Locust-facing single-operation endpoints
		g.POST("/seat/init", h.InitSeat)
		g.POST("/seat/book", h.BookSeat)
		g.GET("/seat/results", h.GetSeatResults)
		g.DELETE("/seat", h.CleanupSeat)
	}
}

func (h *Handler) Health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "healthy", "service": "experiment1"})
}

// POST /api/v1/run — batch runner (spawns goroutines internally)
func (h *Handler) RunExperiment(c *gin.Context) {
	var req RunRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{Error: "INVALID_INPUT", Message: err.Error()})
		return
	}
	result, err := h.runner.Run(c.Request.Context(), req)
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "RUN_FAILED", Message: err.Error()})
		return
	}
	c.JSON(http.StatusOK, result)
}

// POST /api/v1/seat/init — create a fresh seat for a Locust test run
func (h *Handler) InitSeat(c *gin.Context) {
	var req InitSeatRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{Error: "INVALID_INPUT", Message: err.Error()})
		return
	}
	if err := h.runner.InitSeat(c.Request.Context(), req.DBBackend, req.EventID, req.SeatID); err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "INIT_FAILED", Message: err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"event_id": req.EventID, "seat_id": req.SeatID})
}

// POST /api/v1/seat/book — one booking attempt from a Locust worker
// 200 = booking accepted, 409 = seat taken (expected), 500 = infrastructure error
func (h *Handler) BookSeat(c *gin.Context) {
	var req BookSeatRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{Error: "INVALID_INPUT", Message: err.Error()})
		return
	}
	got, err := h.runner.BookSingle(c.Request.Context(), req)
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "BOOK_FAILED", Message: err.Error()})
		return
	}
	if !got {
		c.JSON(http.StatusConflict, BookSeatResponse{BookingID: req.BookingID, Success: false})
		return
	}
	c.JSON(http.StatusOK, BookSeatResponse{BookingID: req.BookingID, Success: true})
}

// GET /api/v1/seat/results?event_id=&seat_id=&db_backend=
func (h *Handler) GetSeatResults(c *gin.Context) {
	eventID := c.Query("event_id")
	seatID := c.Query("seat_id")
	dbBackend := DBBackend(c.Query("db_backend"))
	if eventID == "" || seatID == "" || dbBackend == "" {
		c.JSON(http.StatusBadRequest, ErrorResponse{Error: "INVALID_INPUT", Message: "event_id, seat_id, db_backend required"})
		return
	}
	bookings, oversells, err := h.runner.GetResults(c.Request.Context(), dbBackend, eventID, seatID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "QUERY_FAILED", Message: err.Error()})
		return
	}
	c.JSON(http.StatusOK, SeatResultsResponse{
		EventID:       eventID,
		SeatID:        seatID,
		BookingCount:  bookings,
		OversellCount: oversells,
	})
}

// DELETE /api/v1/seat?event_id=&seat_id=&db_backend=
func (h *Handler) CleanupSeat(c *gin.Context) {
	eventID := c.Query("event_id")
	seatID := c.Query("seat_id")
	dbBackend := DBBackend(c.Query("db_backend"))
	if eventID == "" || seatID == "" || dbBackend == "" {
		c.JSON(http.StatusBadRequest, ErrorResponse{Error: "INVALID_INPUT", Message: "event_id, seat_id, db_backend required"})
		return
	}
	if err := h.runner.CleanupSeat(c.Request.Context(), dbBackend, eventID, seatID); err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "CLEANUP_FAILED", Message: err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "cleaned"})
}

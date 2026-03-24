package main

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

type Handler struct {
	repo Repository
}

func NewHandler(repo Repository) *Handler {
	return &Handler{repo: repo}
}

func (h *Handler) RegisterRoutes(r *gin.Engine) {
	// Health check — both bare (direct) and prefixed (via ALB path routing)
	r.GET("/health", h.Health)
	r.GET("/inventory/health", h.Health)

	// Routes under both prefixes so they work whether hit directly or via ALB
	for _, base := range []string{"", "/inventory"} {
		g := r.Group(base + "/api/v1")
		g.GET("/events", h.ListEvents)
		g.GET("/events/:event_id", h.GetEvent)
		g.GET("/events/:event_id/seats", h.ListSeats)
		g.GET("/events/:event_id/availability", h.GetAvailability)

		internal := g.Group("/internal")
		internal.POST("/events/:event_id/seats/:seat_id/reserve", h.ReserveSeat)
		internal.POST("/events/:event_id/seats/:seat_id/release", h.ReleaseSeat)
	}
}

func (h *Handler) Health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status":  "healthy",
		"service": "inventory-service",
	})
}

func (h *Handler) ListEvents(c *gin.Context) {
	events, err := h.repo.ListEvents(c.Request.Context())
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"DB_ERROR", err.Error()})
		return
	}
	if events == nil {
		events = []Event{}
	}
	c.JSON(http.StatusOK, ListEventsResponse{Events: events, Total: len(events)})
}

func (h *Handler) GetEvent(c *gin.Context) {
	eventID := c.Param("event_id")
	event, err := h.repo.GetEvent(c.Request.Context(), eventID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"DB_ERROR", err.Error()})
		return
	}
	if event == nil {
		c.JSON(http.StatusNotFound, ErrorResponse{"NOT_FOUND", "event not found"})
		return
	}
	c.JSON(http.StatusOK, event)
}

func (h *Handler) ListSeats(c *gin.Context) {
	eventID := c.Param("event_id")
	seats, err := h.repo.ListSeats(c.Request.Context(), eventID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"DB_ERROR", err.Error()})
		return
	}
	if seats == nil {
		seats = []Seat{}
	}
	c.JSON(http.StatusOK, ListSeatsResponse{EventID: eventID, Seats: seats, Total: len(seats)})
}

func (h *Handler) GetAvailability(c *gin.Context) {
	eventID := c.Param("event_id")
	count, err := h.repo.GetAvailableCount(c.Request.Context(), eventID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"DB_ERROR", err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"event_id":        eventID,
		"available_seats": count,
	})
}

func (h *Handler) ReserveSeat(c *gin.Context) {
	eventID := c.Param("event_id")
	seatID := c.Param("seat_id")
	if err := h.repo.ReserveSeat(c.Request.Context(), eventID, seatID); err != nil {
		c.JSON(http.StatusConflict, ErrorResponse{"RESERVE_FAILED", err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"event_id": eventID, "seat_id": seatID, "status": "reserved"})
}

func (h *Handler) ReleaseSeat(c *gin.Context) {
	eventID := c.Param("event_id")
	seatID := c.Param("seat_id")
	if err := h.repo.ReleaseSeat(c.Request.Context(), eventID, seatID); err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"RELEASE_FAILED", err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"event_id": eventID, "seat_id": seatID, "status": "available"})
}
package main

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
)

type Handler struct {
	manager *QueueManager
}

func NewHandler(manager *QueueManager) *Handler {
	return &Handler{manager: manager}
}

func (h *Handler) RegisterRoutes(r *gin.Engine) {
	// Health check — both bare and ALB-prefixed
	r.GET("/health", h.Health)
	r.GET("/queue/health", h.Health)

	for _, base := range []string{"", "/queue"} {
		g := r.Group(base + "/api/v1")
		g.POST("/queue/join", h.JoinQueue)
		g.GET("/queue/metrics", h.GetAllMetrics)
		g.GET("/queue/status/:queue_id", h.GetStatus)
		g.GET("/queue/event/:event_id/metrics", h.GetEventMetrics)
		g.POST("/queue/event/:event_id/admission-rate", h.SetAdmissionRate)
		g.POST("/queue/event/:event_id/fairness-mode", h.SetFairnessMode)
	}
}

func (h *Handler) Health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status":  "healthy",
		"service": "queue-service",
	})
}

func (h *Handler) JoinQueue(c *gin.Context) {
	var req JoinQueueRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{"INVALID_INPUT", err.Error()})
		return
	}

	ip := c.ClientIP()
	q := h.manager.GetOrCreate(req.EventID)

	entry, err := q.Join(req.CustomerID, ip)
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{"QUEUE_ERROR", err.Error()})
		return
	}

	c.JSON(http.StatusCreated, entry)
}

func (h *Handler) GetStatus(c *gin.Context) {
	queueID := c.Param("queue_id")

	metrics := h.manager.AllMetrics()
	for _, m := range metrics {
		q := h.manager.GetOrCreate(m.EventID)
		status, err := q.Status(queueID)
		if err == nil {
			c.JSON(http.StatusOK, status)
			return
		}
	}

	c.JSON(http.StatusNotFound, ErrorResponse{"NOT_FOUND", "queue entry not found"})
}

func (h *Handler) GetAllMetrics(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"queues": h.manager.AllMetrics(),
	})
}

func (h *Handler) GetEventMetrics(c *gin.Context) {
	eventID := c.Param("event_id")
	q := h.manager.GetOrCreate(eventID)
	c.JSON(http.StatusOK, q.Metrics())
}

func (h *Handler) SetAdmissionRate(c *gin.Context) {
	eventID := c.Param("event_id")
	var body struct {
		Rate int `json:"rate" binding:"required"`
	}
	if err := c.ShouldBindJSON(&body); err != nil || body.Rate <= 0 {
		c.JSON(http.StatusBadRequest, ErrorResponse{"INVALID_INPUT", "rate must be a positive integer"})
		return
	}

	q := h.manager.GetOrCreate(eventID)
	q.SetAdmissionRate(body.Rate)
	c.JSON(http.StatusOK, gin.H{
		"event_id":       eventID,
		"admission_rate": strconv.Itoa(body.Rate),
		"message":        "admission rate updated",
	})
}

func (h *Handler) SetFairnessMode(c *gin.Context) {
	eventID := c.Param("event_id")
	var body struct {
		Mode string `json:"mode" binding:"required"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{"INVALID_INPUT", err.Error()})
		return
	}

	var mode FairnessMode
	switch body.Mode {
	case "collapse":
		mode = FairnessCollapse
	case "allow_multiple":
		mode = FairnessAllowMultiple
	default:
		c.JSON(http.StatusBadRequest, ErrorResponse{"INVALID_INPUT", "mode must be 'collapse' or 'allow_multiple'"})
		return
	}

	q := h.manager.GetOrCreate(eventID)
	q.SetFairnessMode(mode)
	c.JSON(http.StatusOK, gin.H{
		"event_id":      eventID,
		"fairness_mode": body.Mode,
		"message":       "fairness mode updated",
	})
}
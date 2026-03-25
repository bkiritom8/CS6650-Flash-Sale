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
		g.POST("/run", h.RunExperiment)
	}
}

// Health godoc
// GET /health
func (h *Handler) Health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status":  "healthy",
		"service": "experiment1",
	})
}

// RunExperiment godoc
// POST /api/v1/run
//
// Body (all fields except lock_mode and db_backend are optional):
//
//	{
//	  "lock_mode":    "none" | "optimistic" | "pessimistic",
//	  "db_backend":  "mysql" | "dynamodb",
//	  "concurrency": 1000,
//	  "max_retries": 3
//	}
func (h *Handler) RunExperiment(c *gin.Context) {
	var req RunRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{
			Error:   "INVALID_INPUT",
			Message: err.Error(),
		})
		return
	}

	result, err := h.runner.Run(c.Request.Context(), req)
	if err != nil {
		c.JSON(http.StatusInternalServerError, ErrorResponse{
			Error:   "RUN_FAILED",
			Message: err.Error(),
		})
		return
	}

	c.JSON(http.StatusOK, result)
}

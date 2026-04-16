package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
)

func main() {
	admissionRateStr := os.Getenv("ADMISSION_RATE")
	if admissionRateStr == "" {
		admissionRateStr = "10" // default: 10 admissions/sec
	}
	admissionRate, err := strconv.Atoi(admissionRateStr)
	if err != nil || admissionRate <= 0 {
		log.Fatalf("invalid ADMISSION_RATE=%q", admissionRateStr)
	}

	fairnessModeStr := os.Getenv("FAIRNESS_MODE")
	if fairnessModeStr == "" {
		fairnessModeStr = "allow_multiple" // default: permissive for baseline
	}
	var fairnessMode FairnessMode
	switch fairnessModeStr {
	case "collapse":
		fairnessMode = FairnessCollapse
	case "allow_multiple":
		fairnessMode = FairnessAllowMultiple
	default:
		log.Fatalf("unknown FAIRNESS_MODE=%q, must be collapse|allow_multiple", fairnessModeStr)
	}

	log.Printf("queue-service starting, admission_rate=%d/s fairness=%s",
		admissionRate, fairnessMode)

	manager := NewQueueManager(admissionRate, fairnessMode)
	defer manager.StopAll()

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())

	h := NewHandler(manager)
	h.RegisterRoutes(r)

	srv := &http.Server{
		Addr:         ":8080",
		Handler:      r,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Println("queue-service listening on :8080")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down queue-service...")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
)

func main() {
	bookingURL := os.Getenv("BOOKING_SERVICE_URL")
	if bookingURL == "" {
		log.Fatal("BOOKING_SERVICE_URL not set — must point to booking-service (e.g. http://<ALB>/booking)")
	}
	log.Printf("experiment1 starting, booking_service=%s", bookingURL)

	runner := NewRunner(bookingURL)

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())

	h := NewHandler(runner)
	h.RegisterRoutes(r)

	srv := &http.Server{
		Addr:         ":8080",
		Handler:      r,
		ReadTimeout:  120 * time.Second,
		WriteTimeout: 120 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Println("experiment1 listening on :8080")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down experiment1...")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}

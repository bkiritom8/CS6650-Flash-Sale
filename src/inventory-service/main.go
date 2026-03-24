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
	backend := os.Getenv("DB_BACKEND")
	log.Printf("inventory-service starting, backend=%s", backend)

	var repo Repository
	var err error

	switch backend {
	case "mysql":
		repo, err = NewMySQLRepo(
			os.Getenv("MYSQL_HOST"),
			os.Getenv("MYSQL_PORT"),
			os.Getenv("MYSQL_USER"),
			os.Getenv("MYSQL_PASSWORD"),
			os.Getenv("MYSQL_DB"),
		)
	case "dynamodb":
		repo, err = NewDynamoDBRepo(
			os.Getenv("AWS_REGION"),
			os.Getenv("DYNAMODB_EVENTS_TABLE"),
			os.Getenv("DYNAMODB_SEATS_TABLE"),
		)
	default:
		log.Fatalf("unknown DB_BACKEND=%q, must be 'mysql' or 'dynamodb'", backend)
	}
	if err != nil {
		log.Fatalf("init repo: %v", err)
	}
	defer repo.Close()

	log.Println("Seeding data...")
	if err := repo.SeedData(context.Background()); err != nil {
		log.Fatalf("seed data: %v", err)
	}
	log.Println("Seed complete.")

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())

	h := NewHandler(repo)
	h.RegisterRoutes(r)

	srv := &http.Server{
		Addr:         ":8080",
		Handler:      r,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Println("inventory-service listening on :8080")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down inventory-service...")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
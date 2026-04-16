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
	lockModeStr := os.Getenv("LOCK_MODE")
	if lockModeStr == "" {
		lockModeStr = "pessimistic"
	}
	inventoryURL := os.Getenv("INVENTORY_SERVICE_URL")

	var lockMode LockMode
	switch lockModeStr {
	case "none":
		lockMode = LockNone
	case "optimistic":
		lockMode = LockOptimistic
	case "pessimistic":
		lockMode = LockPessimistic
	default:
		log.Fatalf("unknown LOCK_MODE=%q, must be none|optimistic|pessimistic", lockModeStr)
	}

	// Init both repos if configured — experiment1 switches backends per request.
	var mysqlRepo, dynamoRepo Repository

	if os.Getenv("MYSQL_HOST") != "" {
		var err error
		mysqlRepo, err = NewMySQLRepo(
			os.Getenv("MYSQL_HOST"),
			getEnv("MYSQL_PORT", "3306"),
			getEnv("MYSQL_USER", "admin"),
			os.Getenv("MYSQL_PASSWORD"),
			getEnv("MYSQL_DB", "concertdb"),
		)
		if err != nil {
			log.Fatalf("init MySQL repo: %v", err)
		}
		defer mysqlRepo.Close()
		log.Printf("MySQL backend ready: %s", os.Getenv("MYSQL_HOST"))
	}

	if os.Getenv("DYNAMODB_BOOKINGS_TABLE") != "" {
		var err error
		dynamoRepo, err = NewDynamoDBRepo(
			getEnv("AWS_REGION", "us-east-1"),
			os.Getenv("DYNAMODB_BOOKINGS_TABLE"),
			os.Getenv("DYNAMODB_VERSIONS_TABLE"),
			os.Getenv("DYNAMODB_OVERSELLS_TABLE"),
		)
		if err != nil {
			log.Fatalf("init DynamoDB repo: %v", err)
		}
		defer dynamoRepo.Close()
		log.Printf("DynamoDB backend ready")
	}

	if mysqlRepo == nil && dynamoRepo == nil {
		log.Fatal("no DB backend configured — set MYSQL_HOST or DYNAMODB_BOOKINGS_TABLE")
	}

	// Default backend: prefer explicit DB_BACKEND env, otherwise whichever is configured.
	defaultBackend := os.Getenv("DB_BACKEND")
	if defaultBackend == "" {
		if mysqlRepo != nil {
			defaultBackend = "mysql"
		} else {
			defaultBackend = "dynamodb"
		}
	}
	log.Printf("booking-service starting, default_backend=%s lock_mode=%s", defaultBackend, lockModeStr)

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())

	h := NewHandler(mysqlRepo, dynamoRepo, defaultBackend, lockMode, inventoryURL)
	h.RegisterRoutes(r)

	srv := &http.Server{
		Addr:         ":8080",
		Handler:      r,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Println("booking-service listening on :8080")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down booking-service...")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

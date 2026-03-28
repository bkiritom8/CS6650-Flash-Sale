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
	log.Println("experiment1 starting...")

	var mysqlRepo Repository
	var dynamoRepo Repository

	// ── MySQL ─────────────────────────────────────────────────────────────────
	mysqlHost := os.Getenv("MYSQL_HOST")
	if mysqlHost != "" {
		var err error
		mysqlRepo, err = NewMySQLRepo(
			mysqlHost,
			getEnvOrDefault("MYSQL_PORT", "3306"),
			getEnvOrDefault("MYSQL_USER", "admin"),
			os.Getenv("MYSQL_PASSWORD"),
			getEnvOrDefault("MYSQL_DB", "concertdb"),
		)
		if err != nil {
			log.Fatalf("init MySQL repo: %v", err)
		}
		defer mysqlRepo.Close()
		log.Printf("MySQL backend ready: %s", mysqlHost)
	} else {
		log.Println("MYSQL_HOST not set — MySQL backend disabled")
	}

	// ── DynamoDB ──────────────────────────────────────────────────────────────
	awsRegion := getEnvOrDefault("AWS_REGION", "us-east-1")
	bookingsTable := os.Getenv("DYNAMODB_BOOKINGS_TABLE")
	versionsTable := os.Getenv("DYNAMODB_VERSIONS_TABLE")
	oversellsTable := os.Getenv("DYNAMODB_OVERSELLS_TABLE")

	if bookingsTable != "" && versionsTable != "" && oversellsTable != "" {
		var err error
		dynamoRepo, err = NewDynamoDBRepo(awsRegion, bookingsTable, versionsTable, oversellsTable)
		if err != nil {
			log.Fatalf("init DynamoDB repo: %v", err)
		}
		defer dynamoRepo.Close()
		log.Printf("DynamoDB backend ready: region=%s", awsRegion)
	} else {
		log.Println("DYNAMODB_*_TABLE env vars not set — DynamoDB backend disabled")
	}

	if mysqlRepo == nil && dynamoRepo == nil {
		log.Fatal("no database backends configured — set MYSQL_HOST or DYNAMODB_*_TABLE env vars")
	}

	runner := NewRunner(mysqlRepo, dynamoRepo)

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())

	h := NewHandler(runner)
	h.RegisterRoutes(r)

	srv := &http.Server{
		Addr:         ":8080",
		Handler:      r,
		ReadTimeout:  120 * time.Second, // experiments can take a while
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

func getEnvOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

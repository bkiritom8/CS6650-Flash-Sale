package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// MongoDBRepo implements Repository using MongoDB (or DocumentDB).
type MongoDBRepo struct {
	client        *mongo.Client
	db            *mongo.Database
	seatVersions  *mongo.Collection
	bookings      *mongo.Collection
	oversells     *mongo.Collection
}

// NewMongoDBRepo connects to MongoDB, pings it, and ensures the unique index
// on {event_id, seat_id} in the seat_versions collection.
// Retries for up to 3 minutes to allow EC2 user_data time to install mongod.
func NewMongoDBRepo(uri, dbName string) (*MongoDBRepo, error) {
	clientOpts := options.Client().
		ApplyURI(uri).
		SetServerSelectionTimeout(10 * time.Second)

	client, err := mongo.Connect(context.Background(), clientOpts)
	if err != nil {
		return nil, fmt.Errorf("mongodb connect: %w", err)
	}

	for i := 0; i < 18; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		err = client.Ping(ctx, nil)
		cancel()
		if err == nil {
			break
		}
		log.Printf("MongoDB not ready, retrying in 10s (%d/18): %v", i+1, err)
		time.Sleep(10 * time.Second)
	}
	if err != nil {
		_ = client.Disconnect(context.Background())
		return nil, fmt.Errorf("could not connect to MongoDB after retries: %w", err)
	}

	db := client.Database(dbName)
	seatVersionsColl := db.Collection("exp1_seat_versions")
	bookingsColl := db.Collection("exp1_bookings")
	oversellsColl := db.Collection("exp1_oversells")

	// Create unique compound index on {event_id, seat_id} in seat_versions.
	indexModel := mongo.IndexModel{
		Keys:    bson.D{{Key: "event_id", Value: 1}, {Key: "seat_id", Value: 1}},
		Options: options.Index().SetUnique(true),
	}
	idxCtx, idxCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer idxCancel()
	if _, err := seatVersionsColl.Indexes().CreateOne(idxCtx, indexModel); err != nil {
		_ = client.Disconnect(context.Background())
		return nil, fmt.Errorf("mongodb create index: %w", err)
	}

	return &MongoDBRepo{
		client:       client,
		db:           db,
		seatVersions: seatVersionsColl,
		bookings:     bookingsColl,
		oversells:    oversellsColl,
	}, nil
}

// InitSeat inserts a fresh seat document into seat_versions.
func (r *MongoDBRepo) InitSeat(ctx context.Context, eventID, seatID string) error {
	doc := bson.M{
		"event_id": eventID,
		"seat_id":  seatID,
		"version":  0,
		"status":   "available",
	}
	_, err := r.seatVersions.InsertOne(ctx, doc)
	return err
}

// BookNoLock reads the current status and records the booking regardless.
// If the seat was not available, it also inserts an oversell record.
// Returns oversold=true if the seat was not "available" at the time of the read.
func (r *MongoDBRepo) BookNoLock(ctx context.Context, eventID, seatID, bookingID string) (bool, error) {
	var seat bson.M
	err := r.seatVersions.FindOne(ctx, bson.M{
		"event_id": eventID,
		"seat_id":  seatID,
	}).Decode(&seat)
	if err != nil {
		return false, fmt.Errorf("BookNoLock find seat: %w", err)
	}

	status, _ := seat["status"].(string)
	oversold := status != "available"

	if oversold {
		oversellDoc := bson.M{
			"event_id":   eventID,
			"seat_id":    seatID,
			"created_at": time.Now(),
		}
		if _, oErr := r.oversells.InsertOne(ctx, oversellDoc); oErr != nil {
			return true, fmt.Errorf("BookNoLock insert oversell: %w", oErr)
		}
	}

	bookingDoc := bson.M{
		"booking_id": bookingID,
		"event_id":   eventID,
		"seat_id":    seatID,
		"lock_mode":  "none",
		"created_at": time.Now(),
	}
	if _, bErr := r.bookings.InsertOne(ctx, bookingDoc); bErr != nil {
		return oversold, fmt.Errorf("BookNoLock insert booking: %w", bErr)
	}

	return oversold, nil
}

// BookOptimistic uses optimistic concurrency: read version → conditional update → retry.
func (r *MongoDBRepo) BookOptimistic(ctx context.Context, eventID, seatID, bookingID string, maxRetries int) error {
	for attempt := 0; attempt < maxRetries; attempt++ {
		var seat bson.M
		err := r.seatVersions.FindOne(ctx, bson.M{
			"event_id": eventID,
			"seat_id":  seatID,
		}).Decode(&seat)
		if err != nil {
			return fmt.Errorf("BookOptimistic find seat: %w", err)
		}

		status, _ := seat["status"].(string)
		if status != "available" {
			return fmt.Errorf("seat not available")
		}

		// version can be stored as int32 or int64 depending on BSON encoding.
		var currentVersion int64
		switch v := seat["version"].(type) {
		case int32:
			currentVersion = int64(v)
		case int64:
			currentVersion = v
		}

		result, err := r.seatVersions.UpdateOne(
			ctx,
			bson.M{
				"event_id": eventID,
				"seat_id":  seatID,
				"version":  currentVersion,
				"status":   "available",
			},
			bson.M{
				"$set": bson.M{"status": "reserved"},
				"$inc": bson.M{"version": 1},
			},
		)
		if err != nil {
			return fmt.Errorf("BookOptimistic update: %w", err)
		}

		if result.MatchedCount > 0 {
			bookingDoc := bson.M{
				"booking_id": bookingID,
				"event_id":   eventID,
				"seat_id":    seatID,
				"lock_mode":  "optimistic",
				"created_at": time.Now(),
			}
			if _, bErr := r.bookings.InsertOne(ctx, bookingDoc); bErr != nil {
				return fmt.Errorf("BookOptimistic insert booking: %w", bErr)
			}
			return nil
		}

		// Conflict — back off and retry.
		time.Sleep(time.Duration(attempt+1) * 5 * time.Millisecond)
	}

	return fmt.Errorf("seat not available after %d retries", maxRetries)
}

// BookPessimistic uses an atomic findOneAndUpdate to grab the seat.
func (r *MongoDBRepo) BookPessimistic(ctx context.Context, eventID, seatID, bookingID string) error {
	var seat bson.M
	err := r.seatVersions.FindOneAndUpdate(
		ctx,
		bson.M{
			"event_id": eventID,
			"seat_id":  seatID,
			"status":   "available",
		},
		bson.M{
			"$set": bson.M{"status": "reserved"},
			"$inc": bson.M{"version": 1},
		},
	).Decode(&seat)
	if err != nil {
		if errors.Is(err, mongo.ErrNoDocuments) {
			return fmt.Errorf("seat not available")
		}
		return fmt.Errorf("BookPessimistic findOneAndUpdate: %w", err)
	}

	bookingDoc := bson.M{
		"booking_id": bookingID,
		"event_id":   eventID,
		"seat_id":    seatID,
		"lock_mode":  "pessimistic",
		"created_at": time.Now(),
	}
	if _, bErr := r.bookings.InsertOne(ctx, bookingDoc); bErr != nil {
		return fmt.Errorf("BookPessimistic insert booking: %w", bErr)
	}
	return nil
}

// CountBookings returns the number of booking documents for the given seat.
func (r *MongoDBRepo) CountBookings(ctx context.Context, eventID, seatID string) (int, error) {
	n, err := r.bookings.CountDocuments(ctx, bson.M{
		"event_id": eventID,
		"seat_id":  seatID,
	})
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

// CountOversells returns max(0, bookingCount-1) as a proxy for oversells.
func (r *MongoDBRepo) CountOversells(ctx context.Context, eventID, seatID string) (int, error) {
	n, err := r.CountBookings(ctx, eventID, seatID)
	if err != nil {
		return 0, err
	}
	if n <= 1 {
		return 0, nil
	}
	return n - 1, nil
}

// Cleanup removes all documents for the given seat across all three collections.
func (r *MongoDBRepo) Cleanup(ctx context.Context, eventID, seatID string) error {
	filter := bson.M{"event_id": eventID, "seat_id": seatID}
	if _, err := r.seatVersions.DeleteOne(ctx, filter); err != nil {
		return fmt.Errorf("Cleanup seat_versions: %w", err)
	}
	if _, err := r.bookings.DeleteMany(ctx, filter); err != nil {
		return fmt.Errorf("Cleanup bookings: %w", err)
	}
	if _, err := r.oversells.DeleteMany(ctx, filter); err != nil {
		return fmt.Errorf("Cleanup oversells: %w", err)
	}
	return nil
}

// Close disconnects the MongoDB client.
func (r *MongoDBRepo) Close() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return r.client.Disconnect(ctx)
}

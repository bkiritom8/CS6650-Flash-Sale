package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awscfg "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

type DynamoDBRepo struct {
	client         *dynamodb.Client
	bookingsTable  string
	versionsTable  string
	oversellsTable string
}

func NewDynamoDBRepo(region, bookingsTable, versionsTable, oversellsTable string) (*DynamoDBRepo, error) {
	cfg, err := awscfg.LoadDefaultConfig(context.Background(), awscfg.WithRegion(region))
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}
	return &DynamoDBRepo{
		client:         dynamodb.NewFromConfig(cfg),
		bookingsTable:  bookingsTable,
		versionsTable:  versionsTable,
		oversellsTable: oversellsTable,
	}, nil
}

func (r *DynamoDBRepo) CreateBooking(ctx context.Context, b *Booking) error {
	_, err := r.client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: aws.String(r.bookingsTable),
		Item: map[string]types.AttributeValue{
			"booking_id":  &types.AttributeValueMemberS{Value: b.BookingID},
			"event_id":    &types.AttributeValueMemberS{Value: b.EventID},
			"seat_id":     &types.AttributeValueMemberS{Value: b.SeatID},
			"customer_id": &types.AttributeValueMemberN{Value: strconv.Itoa(b.CustomerID)},
			"status":      &types.AttributeValueMemberS{Value: b.Status},
			"lock_mode":   &types.AttributeValueMemberS{Value: b.LockMode},
			"created_at":  &types.AttributeValueMemberS{Value: b.CreatedAt.Format(time.RFC3339)},
		},
	})
	return err
}

func (r *DynamoDBRepo) GetBooking(ctx context.Context, bookingID string) (*Booking, error) {
	out, err := r.client.GetItem(ctx, &dynamodb.GetItemInput{
		TableName: aws.String(r.bookingsTable),
		Key: map[string]types.AttributeValue{
			"booking_id": &types.AttributeValueMemberS{Value: bookingID},
		},
	})
	if err != nil {
		return nil, err
	}
	if out.Item == nil {
		return nil, nil
	}
	return r.itemToBooking(out.Item), nil
}

func (r *DynamoDBRepo) ListBookingsByEvent(ctx context.Context, eventID string) ([]Booking, error) {
	out, err := r.client.Query(ctx, &dynamodb.QueryInput{
		TableName:              aws.String(r.bookingsTable),
		IndexName:              aws.String("event_id-index"),
		KeyConditionExpression: aws.String("event_id = :eid"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":eid": &types.AttributeValueMemberS{Value: eventID},
		},
	})
	if err != nil {
		return nil, err
	}

	var bookings []Booking
	for _, item := range out.Items {
		bookings = append(bookings, *r.itemToBooking(item))
	}
	return bookings, nil
}

func (r *DynamoDBRepo) CancelBooking(ctx context.Context, bookingID string) error {
	_, err := r.client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName: aws.String(r.bookingsTable),
		Key: map[string]types.AttributeValue{
			"booking_id": &types.AttributeValueMemberS{Value: bookingID},
		},
		UpdateExpression: aws.String("SET #s = :cancelled"),
		ExpressionAttributeNames:  map[string]string{"#s": "status"},
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":cancelled": &types.AttributeValueMemberS{Value: "cancelled"},
		},
	})
	return err
}

// ── No-lock mode ──────────────────────────────────────────────────────────────
// Reads status then writes without condition — race window intentional for Exp 1.

func (r *DynamoDBRepo) CheckAndReserveNoLock(ctx context.Context, eventID, seatID string, b *Booking) error {
	vk := r.versionKey(eventID, seatID)

	// Ensure record exists
	_, err := r.client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName:           aws.String(r.versionsTable),
		ConditionExpression: aws.String("attribute_not_exists(seat_id)"),
		Item: map[string]types.AttributeValue{
			"event_id": &types.AttributeValueMemberS{Value: eventID},
			"seat_id":  &types.AttributeValueMemberS{Value: seatID},
			"version":  &types.AttributeValueMemberN{Value: "0"},
			"status":   &types.AttributeValueMemberS{Value: "available"},
		},
	})
	if err != nil {
		var condErr *types.ConditionalCheckFailedException
		if !errors.As(err, &condErr) {
			return fmt.Errorf("init seat version %s: %w", seatID, err)
		}
	}

	out, err := r.client.GetItem(ctx, &dynamodb.GetItemInput{
		TableName: aws.String(r.versionsTable),
		Key:       vk,
	})
	if err != nil {
		return err
	}

	if out.Item != nil {
		status := out.Item["status"].(*types.AttributeValueMemberS).Value
		if status != "available" {
			_, _ = r.client.PutItem(ctx, &dynamodb.PutItemInput{
				TableName: aws.String(r.oversellsTable),
				Item: map[string]types.AttributeValue{
					"oversell_id": &types.AttributeValueMemberS{Value: fmt.Sprintf("%s-%s-%d", eventID, seatID, time.Now().UnixNano())},
					"event_id":    &types.AttributeValueMemberS{Value: eventID},
					"seat_id":     &types.AttributeValueMemberS{Value: seatID},
					"created_at":  &types.AttributeValueMemberS{Value: time.Now().UTC().Format(time.RFC3339)},
				},
			})
		}
	}

	return r.CreateBooking(ctx, b)
}

// ── Optimistic locking ────────────────────────────────────────────────────────
// Uses DynamoDB conditional writes (version attribute) — native to DynamoDB.

func (r *DynamoDBRepo) CheckAndReserveOptimistic(ctx context.Context, eventID, seatID string, b *Booking, maxRetries int) error {
	vk := r.versionKey(eventID, seatID)

	for attempt := 0; attempt <= maxRetries; attempt++ {
		out, err := r.client.GetItem(ctx, &dynamodb.GetItemInput{
			TableName: aws.String(r.versionsTable),
			Key:       vk,
		})
		if err != nil {
			return err
		}

		var currentVersion int
		if out.Item == nil {
			// Initialise seat version record
			_, err = r.client.PutItem(ctx, &dynamodb.PutItemInput{
				TableName:           aws.String(r.versionsTable),
				Item: map[string]types.AttributeValue{
					"event_id": &types.AttributeValueMemberS{Value: eventID},
					"seat_id":  &types.AttributeValueMemberS{Value: seatID},
					"version":  &types.AttributeValueMemberN{Value: "0"},
					"status":   &types.AttributeValueMemberS{Value: "available"},
				},
				ConditionExpression: aws.String("attribute_not_exists(seat_id)"),
			})
			if err != nil {
				continue // another writer initialised concurrently, retry
			}
			currentVersion = 0
		} else {
			status := out.Item["status"].(*types.AttributeValueMemberS).Value
			if status != "available" {
				return fmt.Errorf("seat %s is not available", seatID)
			}
			v, _ := strconv.Atoi(out.Item["version"].(*types.AttributeValueMemberN).Value)
			currentVersion = v
		}

		// Conditional update — only succeeds if version still matches
		_, err = r.client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
			TableName: aws.String(r.versionsTable),
			Key:       vk,
			UpdateExpression:    aws.String("SET #s = :reserved, version = :newv"),
			ConditionExpression: aws.String("version = :oldv AND #s = :available"),
			ExpressionAttributeNames: map[string]string{"#s": "status"},
			ExpressionAttributeValues: map[string]types.AttributeValue{
				":reserved":  &types.AttributeValueMemberS{Value: "reserved"},
				":available": &types.AttributeValueMemberS{Value: "available"},
				":oldv":      &types.AttributeValueMemberN{Value: strconv.Itoa(currentVersion)},
				":newv":      &types.AttributeValueMemberN{Value: strconv.Itoa(currentVersion + 1)},
			},
		})
		if err == nil {
			return r.CreateBooking(ctx, b)
		}

		log.Printf("optimistic conflict on seat %s (attempt %d/%d)", seatID, attempt+1, maxRetries)
		time.Sleep(time.Duration(attempt*10) * time.Millisecond)
	}
	return fmt.Errorf("seat %s: max retries exceeded under contention", seatID)
}

// ── Pessimistic locking ───────────────────────────────────────────────────────
// DynamoDB has no row-level locks. We simulate pessimistic behaviour using a
// strongly consistent conditional write with an "in_progress" fence attribute.
// This is the closest DynamoDB equivalent and produces similar serialisation effects.

func (r *DynamoDBRepo) CheckAndReservePessimistic(ctx context.Context, eventID, seatID string, b *Booking) error {
	vk := r.versionKey(eventID, seatID)

	// Ensure the seat version record exists before attempting to lock it
	_, err := r.client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName:           aws.String(r.versionsTable),
		ConditionExpression: aws.String("attribute_not_exists(seat_id)"),
		Item: map[string]types.AttributeValue{
			"event_id":    &types.AttributeValueMemberS{Value: eventID},
			"seat_id":     &types.AttributeValueMemberS{Value: seatID},
			"version":     &types.AttributeValueMemberN{Value: "0"},
			"status":      &types.AttributeValueMemberS{Value: "available"},
			"in_progress": &types.AttributeValueMemberBOOL{Value: false},
		},
	})
	// Ignore ConditionalCheckFailedException — means record already exists, that's fine
	if err != nil {
		var condErr *types.ConditionalCheckFailedException
		if !errors.As(err, &condErr) {
			return fmt.Errorf("init seat version %s: %w", seatID, err)
		}
	}

	// Acquire "lock" — set in_progress flag atomically, fail if already set or reserved
	_, err = r.client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName:        aws.String(r.versionsTable),
		Key:              vk,
		UpdateExpression: aws.String("SET in_progress = :t"),
		ConditionExpression: aws.String(
			"#s = :available AND (attribute_not_exists(in_progress) OR in_progress = :f)"),
		ExpressionAttributeNames: map[string]string{"#s": "status"},
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":available": &types.AttributeValueMemberS{Value: "available"},
			":t":         &types.AttributeValueMemberBOOL{Value: true},
			":f":         &types.AttributeValueMemberBOOL{Value: false},
		},
	})
	if err != nil {
		return fmt.Errorf("seat %s not available or already being processed: %w", seatID, err)
	}

	// Critical section — create booking then release "lock"
	bookingErr := r.CreateBooking(ctx, b)

	// Always release fence, even on booking failure
	finalStatus := "reserved"
	if bookingErr != nil {
		finalStatus = "available"
	}
	_, _ = r.client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName: aws.String(r.versionsTable),
		Key:       vk,
		UpdateExpression: aws.String("SET #s = :status, in_progress = :f"),
		ExpressionAttributeNames: map[string]string{"#s": "status"},
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":status": &types.AttributeValueMemberS{Value: finalStatus},
			":f":      &types.AttributeValueMemberBOOL{Value: false},
		},
	})

	return bookingErr
}

func (r *DynamoDBRepo) CountOversells(ctx context.Context, eventID string) (int, error) {
	out, err := r.client.Query(ctx, &dynamodb.QueryInput{
		TableName:              aws.String(r.oversellsTable),
		IndexName:              aws.String("event_id-index"),
		KeyConditionExpression: aws.String("event_id = :eid"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":eid": &types.AttributeValueMemberS{Value: eventID},
		},
		Select: types.SelectCount,
	})
	if err != nil {
		return 0, err
	}
	return int(out.Count), nil
}

func (r *DynamoDBRepo) versionKey(eventID, seatID string) map[string]types.AttributeValue {
	return map[string]types.AttributeValue{
		"event_id": &types.AttributeValueMemberS{Value: eventID},
		"seat_id":  &types.AttributeValueMemberS{Value: seatID},
	}
}

func (r *DynamoDBRepo) itemToBooking(item map[string]types.AttributeValue) *Booking {
	cid, _ := strconv.Atoi(item["customer_id"].(*types.AttributeValueMemberN).Value)
	t, _ := time.Parse(time.RFC3339, item["created_at"].(*types.AttributeValueMemberS).Value)
	return &Booking{
		BookingID:  item["booking_id"].(*types.AttributeValueMemberS).Value,
		EventID:    item["event_id"].(*types.AttributeValueMemberS).Value,
		SeatID:     item["seat_id"].(*types.AttributeValueMemberS).Value,
		CustomerID: cid,
		Status:     item["status"].(*types.AttributeValueMemberS).Value,
		LockMode:   item["lock_mode"].(*types.AttributeValueMemberS).Value,
		CreatedAt:  t,
	}
}

func (r *DynamoDBRepo) Close() error { return nil }
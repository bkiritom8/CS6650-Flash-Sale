package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awscfg "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/google/uuid"
)

// DynamoDBRepo implements the three concurrency strategies using DynamoDB primitives:
//
//   - NoLock      — GetItem (no condition) then PutItem; racy by design.
//   - Optimistic  — UpdateItem with version + status ConditionExpression, retry on conflict.
//   - Pessimistic — TransactWriteItems combining condition-check + update + put atomically;
//     no retry — models the "serialized" semantic without a native row lock.
//
// Table layout (shared with booking-service, isolated by event_id prefix "exp1-<runID>"):
//
//	versionsTable  PK=event_id  SK=seat_id  attrs: version(N), status(S)
//	bookingsTable  PK=booking_id            attrs: event_id(S), seat_id(S), lock_mode(S)
//	oversellsTable PK=oversell_id           attrs: event_id(S), seat_id(S)
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
	log.Printf("DynamoDB repo initialised: region=%s bookings=%s versions=%s oversells=%s",
		region, bookingsTable, versionsTable, oversellsTable)
	return &DynamoDBRepo{
		client:         dynamodb.NewFromConfig(cfg),
		bookingsTable:  bookingsTable,
		versionsTable:  versionsTable,
		oversellsTable: oversellsTable,
	}, nil
}

// ── InitSeat ──────────────────────────────────────────────────────────────────

func (r *DynamoDBRepo) InitSeat(ctx context.Context, eventID, seatID string) error {
	_, err := r.client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: aws.String(r.versionsTable),
		Item: map[string]types.AttributeValue{
			"event_id": &types.AttributeValueMemberS{Value: eventID},
			"seat_id":  &types.AttributeValueMemberS{Value: seatID},
			"version":  &types.AttributeValueMemberN{Value: "0"},
			"status":   &types.AttributeValueMemberS{Value: "available"},
		},
		// Fail if this run's seat was somehow already created.
		ConditionExpression: aws.String("attribute_not_exists(event_id)"),
	})
	return err
}

// ── No-lock mode ──────────────────────────────────────────────────────────────
// GetItem to read status, then PutItem for booking — no condition on seat state.
// The gap between Get and Put is the race window.

func (r *DynamoDBRepo) BookNoLock(ctx context.Context, eventID, seatID, bookingID string) (bool, error) {
	out, err := r.client.GetItem(ctx, &dynamodb.GetItemInput{
		TableName:      aws.String(r.versionsTable),
		ConsistentRead: aws.Bool(true),
		Key: map[string]types.AttributeValue{
			"event_id": &types.AttributeValueMemberS{Value: eventID},
			"seat_id":  &types.AttributeValueMemberS{Value: seatID},
		},
	})
	if err != nil {
		return false, err
	}

	statusAttr, ok := out.Item["status"]
	oversold := !ok || statusAttr.(*types.AttributeValueMemberS).Value != "available"

	if oversold {
		// Record the oversell event.
		_, _ = r.client.PutItem(ctx, &dynamodb.PutItemInput{
			TableName: aws.String(r.oversellsTable),
			Item: map[string]types.AttributeValue{
				"oversell_id": &types.AttributeValueMemberS{Value: uuid.New().String()},
				"event_id":    &types.AttributeValueMemberS{Value: eventID},
				"seat_id":     &types.AttributeValueMemberS{Value: seatID},
				"at":          &types.AttributeValueMemberS{Value: time.Now().UTC().Format(time.RFC3339)},
			},
		})
	}

	// Write booking unconditionally — unsafe by design.
	_, err = r.client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: aws.String(r.bookingsTable),
		Item: map[string]types.AttributeValue{
			"booking_id": &types.AttributeValueMemberS{Value: bookingID},
			"event_id":   &types.AttributeValueMemberS{Value: eventID},
			"seat_id":    &types.AttributeValueMemberS{Value: seatID},
			"lock_mode":  &types.AttributeValueMemberS{Value: "none"},
			"created_at": &types.AttributeValueMemberS{Value: time.Now().UTC().Format(time.RFC3339)},
		},
	})
	return oversold, err
}

// ── Optimistic locking ────────────────────────────────────────────────────────
// Read version + status → conditional UpdateItem (version must match) → retry.
// Uses DynamoDB's item-level conditional writes; no server-side lock held.

func (r *DynamoDBRepo) BookOptimistic(ctx context.Context, eventID, seatID, bookingID string, maxRetries int) error {
	for attempt := 0; attempt <= maxRetries; attempt++ {
		out, err := r.client.GetItem(ctx, &dynamodb.GetItemInput{
			TableName:      aws.String(r.versionsTable),
			ConsistentRead: aws.Bool(true),
			Key: map[string]types.AttributeValue{
				"event_id": &types.AttributeValueMemberS{Value: eventID},
				"seat_id":  &types.AttributeValueMemberS{Value: seatID},
			},
		})
		if err != nil {
			return err
		}

		statusAttr, ok := out.Item["status"]
		if !ok || statusAttr.(*types.AttributeValueMemberS).Value != "available" {
			return fmt.Errorf("seat not available")
		}

		versionAttr := out.Item["version"].(*types.AttributeValueMemberN).Value

		// Conditional update: only proceeds if version still matches what we read.
		_, err = r.client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
			TableName: aws.String(r.versionsTable),
			Key: map[string]types.AttributeValue{
				"event_id": &types.AttributeValueMemberS{Value: eventID},
				"seat_id":  &types.AttributeValueMemberS{Value: seatID},
			},
			UpdateExpression:    aws.String("SET #s = :reserved, version = version + :one"),
			ConditionExpression: aws.String("version = :ver AND #s = :avail"),
			ExpressionAttributeNames: map[string]string{
				"#s": "status",
			},
			ExpressionAttributeValues: map[string]types.AttributeValue{
				":reserved": &types.AttributeValueMemberS{Value: "reserved"},
				":avail":    &types.AttributeValueMemberS{Value: "available"},
				":ver":      &types.AttributeValueMemberN{Value: versionAttr},
				":one":      &types.AttributeValueMemberN{Value: "1"},
			},
		})
		if err != nil {
			var condErr *types.ConditionalCheckFailedException
			if isCondErr(err, &condErr) {
				// Someone else updated the version — back off and retry.
				time.Sleep(time.Duration(attempt*5) * time.Millisecond)
				continue
			}
			return err
		}

		// Won the race — write the booking.
		_, err = r.client.PutItem(ctx, &dynamodb.PutItemInput{
			TableName: aws.String(r.bookingsTable),
			Item: map[string]types.AttributeValue{
				"booking_id": &types.AttributeValueMemberS{Value: bookingID},
				"event_id":   &types.AttributeValueMemberS{Value: eventID},
				"seat_id":    &types.AttributeValueMemberS{Value: seatID},
				"lock_mode":  &types.AttributeValueMemberS{Value: "optimistic"},
				"created_at": &types.AttributeValueMemberS{Value: time.Now().UTC().Format(time.RFC3339)},
			},
		})
		return err
	}
	return fmt.Errorf("seat not available after %d retries", maxRetries)
}

// ── Pessimistic locking ───────────────────────────────────────────────────────
// TransactWriteItems atomically checks availability, reserves the seat, and
// records the booking in a single ACID transaction.
// DynamoDB has no row-level blocking lock; the transaction replaces it with an
// atomic compare-and-set — writers that arrive concurrently see a failed
// condition and get an immediate error (no queuing).

func (r *DynamoDBRepo) BookPessimistic(ctx context.Context, eventID, seatID, bookingID string) error {
	_, err := r.client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
		TransactItems: []types.TransactWriteItem{
			// 1. Reserve seat atomically — conditional update fails if not available.
			//    (ConditionCheck + Update on the same item is not allowed in DynamoDB
			//    transactions; merge them into a single conditional Update instead.)
			{
				Update: &types.Update{
					TableName: aws.String(r.versionsTable),
					Key: map[string]types.AttributeValue{
						"event_id": &types.AttributeValueMemberS{Value: eventID},
						"seat_id":  &types.AttributeValueMemberS{Value: seatID},
					},
					UpdateExpression:    aws.String("SET #s = :reserved, version = version + :one"),
					ConditionExpression: aws.String("#s = :avail"),
					ExpressionAttributeNames: map[string]string{
						"#s": "status",
					},
					ExpressionAttributeValues: map[string]types.AttributeValue{
						":reserved": &types.AttributeValueMemberS{Value: "reserved"},
						":avail":    &types.AttributeValueMemberS{Value: "available"},
						":one":      &types.AttributeValueMemberN{Value: "1"},
					},
				},
			},
			// 2. Write the booking record.
			{
				Put: &types.Put{
					TableName: aws.String(r.bookingsTable),
					Item: map[string]types.AttributeValue{
						"booking_id": &types.AttributeValueMemberS{Value: bookingID},
						"event_id":   &types.AttributeValueMemberS{Value: eventID},
						"seat_id":    &types.AttributeValueMemberS{Value: seatID},
						"lock_mode":  &types.AttributeValueMemberS{Value: "pessimistic"},
						"created_at": &types.AttributeValueMemberS{Value: time.Now().UTC().Format(time.RFC3339)},
					},
				},
			},
		},
	})
	if err != nil {
		var txErr *types.TransactionCanceledException
		if isTransactionCancelled(err, &txErr) {
			return fmt.Errorf("seat not available")
		}
		return err
	}
	return nil
}

// ── Metrics ───────────────────────────────────────────────────────────────────

func (r *DynamoDBRepo) CountBookings(ctx context.Context, eventID, seatID string) (int, error) {
	out, err := r.client.Query(ctx, &dynamodb.QueryInput{
		TableName:              aws.String(r.bookingsTable),
		IndexName:              aws.String("event_id-index"),
		KeyConditionExpression: aws.String("event_id = :eid"),
		FilterExpression:       aws.String("seat_id = :sid"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":eid": &types.AttributeValueMemberS{Value: eventID},
			":sid": &types.AttributeValueMemberS{Value: seatID},
		},
		Select: types.SelectCount,
	})
	if err != nil {
		return 0, err
	}
	return int(out.Count), nil
}

func (r *DynamoDBRepo) CountOversells(ctx context.Context, eventID, seatID string) (int, error) {
	n, err := r.CountBookings(ctx, eventID, seatID)
	if err != nil {
		return 0, err
	}
	if n > 1 {
		return n - 1, nil
	}
	return 0, nil
}

// ── Cleanup ───────────────────────────────────────────────────────────────────
// DynamoDB has no DELETE WHERE — we scan for matching items then delete them.

func (r *DynamoDBRepo) Cleanup(ctx context.Context, eventID, seatID string) error {
	// Delete seat version record.
	_, _ = r.client.DeleteItem(ctx, &dynamodb.DeleteItemInput{
		TableName: aws.String(r.versionsTable),
		Key: map[string]types.AttributeValue{
			"event_id": &types.AttributeValueMemberS{Value: eventID},
			"seat_id":  &types.AttributeValueMemberS{Value: seatID},
		},
	})

	// Delete bookings via GSI scan + batch delete.
	r.deleteByEventSeat(ctx, r.bookingsTable, "booking_id", eventID, seatID)

	// Delete oversell events via GSI scan + batch delete.
	r.deleteByEventSeat(ctx, r.oversellsTable, "oversell_id", eventID, seatID)

	return nil
}

// deleteByEventSeat queries the event_id-index GSI and batch-deletes matching items.
func (r *DynamoDBRepo) deleteByEventSeat(ctx context.Context, table, pkAttr, eventID, seatID string) {
	out, err := r.client.Query(ctx, &dynamodb.QueryInput{
		TableName:              aws.String(table),
		IndexName:              aws.String("event_id-index"),
		KeyConditionExpression: aws.String("event_id = :eid"),
		FilterExpression:       aws.String("seat_id = :sid"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":eid": &types.AttributeValueMemberS{Value: eventID},
			":sid": &types.AttributeValueMemberS{Value: seatID},
		},
		ProjectionExpression: aws.String(pkAttr),
	})
	if err != nil || len(out.Items) == 0 {
		return
	}

	// Build batch-delete requests (max 25 per BatchWriteItem call).
	const batchSize = 25
	for i := 0; i < len(out.Items); i += batchSize {
		end := i + batchSize
		if end > len(out.Items) {
			end = len(out.Items)
		}
		var reqs []types.WriteRequest
		for _, item := range out.Items[i:end] {
			reqs = append(reqs, types.WriteRequest{
				DeleteRequest: &types.DeleteRequest{
					Key: map[string]types.AttributeValue{pkAttr: item[pkAttr]},
				},
			})
		}
		_, _ = r.client.BatchWriteItem(ctx, &dynamodb.BatchWriteItemInput{
			RequestItems: map[string][]types.WriteRequest{table: reqs},
		})
	}
}

func (r *DynamoDBRepo) Close() error { return nil }

// ── Error helpers ─────────────────────────────────────────────────────────────

func isCondErr(err error, target **types.ConditionalCheckFailedException) bool {
	if err == nil {
		return false
	}
	if e, ok := err.(*types.ConditionalCheckFailedException); ok {
		*target = e
		return true
	}
	return false
}

func isTransactionCancelled(err error, target **types.TransactionCanceledException) bool {
	if err == nil {
		return false
	}
	if e, ok := err.(*types.TransactionCanceledException); ok {
		*target = e
		return true
	}
	return false
}

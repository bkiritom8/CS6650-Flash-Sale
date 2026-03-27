package main

import (
	"context"
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
	client      *dynamodb.Client
	eventsTable string
	seatsTable  string
}

func NewDynamoDBRepo(region, eventsTable, seatsTable string) (*DynamoDBRepo, error) {
	cfg, err := awscfg.LoadDefaultConfig(context.Background(),
		awscfg.WithRegion(region),
	)
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}
	return &DynamoDBRepo{
		client:      dynamodb.NewFromConfig(cfg),
		eventsTable: eventsTable,
		seatsTable:  seatsTable,
	}, nil
}

func (r *DynamoDBRepo) SeedData(ctx context.Context) error {
	for _, e := range seedEvents {
		// Skip if exists
		out, _ := r.client.GetItem(ctx, &dynamodb.GetItemInput{
			TableName: aws.String(r.eventsTable),
			Key: map[string]types.AttributeValue{
				"event_id": &types.AttributeValueMemberS{Value: e.id},
			},
		})
		if out != nil && out.Item != nil {
			continue
		}

		now := time.Now().UTC().Format(time.RFC3339)
		_, err := r.client.PutItem(ctx, &dynamodb.PutItemInput{
			TableName: aws.String(r.eventsTable),
			Item: map[string]types.AttributeValue{
				"event_id":    &types.AttributeValueMemberS{Value: e.id},
				"name":        &types.AttributeValueMemberS{Value: e.name},
				"venue":       &types.AttributeValueMemberS{Value: e.venue},
				"date":        &types.AttributeValueMemberS{Value: e.date},
				"total_seats": &types.AttributeValueMemberN{Value: strconv.Itoa(e.totalSeats)},
				"available":   &types.AttributeValueMemberN{Value: strconv.Itoa(e.totalSeats)},
				"price":       &types.AttributeValueMemberN{Value: fmt.Sprintf("%.2f", e.price)},
				"created_at":  &types.AttributeValueMemberS{Value: now},
			},
		})
		if err != nil {
			return fmt.Errorf("seed event %s: %w", e.id, err)
		}

		// Seed seats in batches of 25 (DynamoDB BatchWriteItem limit)
		var requests []types.WriteRequest
		for i := 1; i <= e.totalSeats; i++ {
			seatID := fmt.Sprintf("%s-seat-%04d", e.id, i)
			seatNo := fmt.Sprintf("S%04d", i)
			requests = append(requests, types.WriteRequest{
				PutRequest: &types.PutRequest{
					Item: map[string]types.AttributeValue{
						"seat_id":    &types.AttributeValueMemberS{Value: seatID},
						"event_id":   &types.AttributeValueMemberS{Value: e.id},
						"seat_no":    &types.AttributeValueMemberS{Value: seatNo},
						"status":     &types.AttributeValueMemberS{Value: "available"},
						"created_at": &types.AttributeValueMemberS{Value: now},
					},
				},
			})

			if len(requests) == 25 || i == e.totalSeats {
				_, err := r.client.BatchWriteItem(ctx, &dynamodb.BatchWriteItemInput{
					RequestItems: map[string][]types.WriteRequest{
						r.seatsTable: requests,
					},
				})
				if err != nil {
					return fmt.Errorf("batch seed seats for %s: %w", e.id, err)
				}
				requests = nil
			}
		}
		log.Printf("Seeded event %s with %d seats", e.id, e.totalSeats)
	}
	return nil
}

func (r *DynamoDBRepo) ListEvents(ctx context.Context) ([]Event, error) {
	out, err := r.client.Scan(ctx, &dynamodb.ScanInput{
		TableName: aws.String(r.eventsTable),
	})
	if err != nil {
		return nil, err
	}

	var events []Event
	for _, item := range out.Items {
		events = append(events, r.itemToEvent(item))
	}
	return events, nil
}

func (r *DynamoDBRepo) GetEvent(ctx context.Context, eventID string) (*Event, error) {
	out, err := r.client.GetItem(ctx, &dynamodb.GetItemInput{
		TableName: aws.String(r.eventsTable),
		Key: map[string]types.AttributeValue{
			"event_id": &types.AttributeValueMemberS{Value: eventID},
		},
	})
	if err != nil {
		return nil, err
	}
	if out.Item == nil {
		return nil, nil
	}
	e := r.itemToEvent(out.Item)
	return &e, nil
}

func (r *DynamoDBRepo) ListSeats(ctx context.Context, eventID string) ([]Seat, error) {
	out, err := r.client.Query(ctx, &dynamodb.QueryInput{
		TableName:              aws.String(r.seatsTable),
		IndexName:              aws.String("event_id-index"),
		KeyConditionExpression: aws.String("event_id = :eid"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":eid": &types.AttributeValueMemberS{Value: eventID},
		},
	})
	if err != nil {
		return nil, err
	}

	var seats []Seat
	for _, item := range out.Items {
		seats = append(seats, r.itemToSeat(item))
	}
	return seats, nil
}

func (r *DynamoDBRepo) GetAvailableCount(ctx context.Context, eventID string) (int, error) {
	out, err := r.client.GetItem(ctx, &dynamodb.GetItemInput{
		TableName: aws.String(r.eventsTable),
		Key: map[string]types.AttributeValue{
			"event_id": &types.AttributeValueMemberS{Value: eventID},
		},
		ProjectionExpression: aws.String("available"),
	})
	if err != nil {
		return 0, err
	}
	if out.Item == nil {
		return 0, fmt.Errorf("event not found: %s", eventID)
	}
	n, _ := strconv.Atoi(out.Item["available"].(*types.AttributeValueMemberN).Value)
	return n, nil
}

func (r *DynamoDBRepo) ReserveSeat(ctx context.Context, eventID, seatID string) error {
	// Atomic conditional update on seat — only if currently available
	_, err := r.client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName: aws.String(r.seatsTable),
		Key: map[string]types.AttributeValue{
			"seat_id": &types.AttributeValueMemberS{Value: seatID},
		},
		UpdateExpression:    aws.String("SET #s = :reserved"),
		ConditionExpression: aws.String("#s = :available AND event_id = :eid"),
		ExpressionAttributeNames: map[string]string{
			"#s": "status",
		},
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":reserved":  &types.AttributeValueMemberS{Value: "reserved"},
			":available": &types.AttributeValueMemberS{Value: "available"},
			":eid":       &types.AttributeValueMemberS{Value: eventID},
		},
	})
	if err != nil {
		return fmt.Errorf("reserve seat %s: %w", seatID, err)
	}

	// Decrement available count atomically
	_, err = r.client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName: aws.String(r.eventsTable),
		Key: map[string]types.AttributeValue{
			"event_id": &types.AttributeValueMemberS{Value: eventID},
		},
		UpdateExpression:    aws.String("SET available = available - :one"),
		ConditionExpression: aws.String("available > :zero"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":one":  &types.AttributeValueMemberN{Value: "1"},
			":zero": &types.AttributeValueMemberN{Value: "0"},
		},
	})
	return err
}

func (r *DynamoDBRepo) ReleaseSeat(ctx context.Context, eventID, seatID string) error {
	_, err := r.client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName: aws.String(r.seatsTable),
		Key: map[string]types.AttributeValue{
			"seat_id": &types.AttributeValueMemberS{Value: seatID},
		},
		UpdateExpression: aws.String("SET #s = :available"),
		ExpressionAttributeNames: map[string]string{
			"#s": "status",
		},
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":available": &types.AttributeValueMemberS{Value: "available"},
		},
	})
	if err != nil {
		return err
	}

	_, err = r.client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName: aws.String(r.eventsTable),
		Key: map[string]types.AttributeValue{
			"event_id": &types.AttributeValueMemberS{Value: eventID},
		},
		UpdateExpression: aws.String("SET available = available + :one"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":one": &types.AttributeValueMemberN{Value: "1"},
		},
	})
	return err
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func (r *DynamoDBRepo) itemToEvent(item map[string]types.AttributeValue) Event {
	totalSeats, _ := strconv.Atoi(item["total_seats"].(*types.AttributeValueMemberN).Value)
	available, _ := strconv.Atoi(item["available"].(*types.AttributeValueMemberN).Value)
	price, _ := strconv.ParseFloat(item["price"].(*types.AttributeValueMemberN).Value, 64)
	createdAt, _ := time.Parse(time.RFC3339, item["created_at"].(*types.AttributeValueMemberS).Value)
	return Event{
		EventID:    item["event_id"].(*types.AttributeValueMemberS).Value,
		Name:       item["name"].(*types.AttributeValueMemberS).Value,
		Venue:      item["venue"].(*types.AttributeValueMemberS).Value,
		Date:       item["date"].(*types.AttributeValueMemberS).Value,
		TotalSeats: totalSeats,
		Available:  available,
		Price:      price,
		CreatedAt:  createdAt,
	}
}

func (r *DynamoDBRepo) itemToSeat(item map[string]types.AttributeValue) Seat {
	createdAt, _ := time.Parse(time.RFC3339, item["created_at"].(*types.AttributeValueMemberS).Value)
	return Seat{
		SeatID:    item["seat_id"].(*types.AttributeValueMemberS).Value,
		EventID:   item["event_id"].(*types.AttributeValueMemberS).Value,
		SeatNo:    item["seat_no"].(*types.AttributeValueMemberS).Value,
		Status:    item["status"].(*types.AttributeValueMemberS).Value,
		CreatedAt: createdAt,
	}
}

func (r *DynamoDBRepo) ResetInventory(ctx context.Context) error {
	// Scan and delete all items from seats table (DynamoDB doesn't support truncate, so we scan and delete)
	var lastEvaluatedKey map[string]types.AttributeValue
	input := &dynamodb.ScanInput{
		TableName:         aws.String(r.seatsTable),
		ExclusiveStartKey: lastEvaluatedKey,
	}
	for {
		out, err := r.client.Scan(ctx, input)
		if err != nil {
			return fmt.Errorf("deleting seat: %w", err)
		}
		lastEvaluatedKey = out.LastEvaluatedKey

		if lastEvaluatedKey == nil {
			break
		}

	}

	// Scan and delete all items from events table
	lastEvaluatedKey = nil
	input = &dynamodb.ScanInput{
		TableName:         aws.String(r.eventsTable),
		ExclusiveStartKey: lastEvaluatedKey,
	}
	for {
		out, err := r.client.Scan(ctx, input)
		if err != nil {
			return fmt.Errorf("deleting event: %w", err)
		}
		lastEvaluatedKey = out.LastEvaluatedKey

		if lastEvaluatedKey == nil {
			break
		}

	}
	return r.SeedData(ctx)
}

func (r *DynamoDBRepo) Close() error { return nil }

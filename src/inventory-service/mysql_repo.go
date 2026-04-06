package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"time"

	"github.com/go-sql-driver/mysql"
	_ "github.com/go-sql-driver/mysql"
)

type MySQLRepo struct {
	db *sql.DB
}

func NewMySQLRepo(host, port, user, pass, dbname string) (*MySQLRepo, error) {
	cfg := mysql.Config{
		User:                 user,
		Passwd:               pass,
		Net:                  "tcp",
		Addr:                 fmt.Sprintf("%s:%s", host, port),
		DBName:               dbname,
		AllowNativePasswords: true,
		ParseTime:            true,
	}

	var db *sql.DB
	var err error
	for i := 0; i < 18; i++ {
		db, err = sql.Open("mysql", cfg.FormatDSN())
		if err == nil {
			err = db.Ping()
		}
		if err == nil {
			break
		}
		log.Printf("MySQL not ready, retrying in 10s (%d/18): %v", i+1, err)
		time.Sleep(10 * time.Second)
	}
	if err != nil {
		return nil, fmt.Errorf("could not connect to MySQL: %w", err)
	}

	db.SetMaxOpenConns(60)
	db.SetMaxIdleConns(20)
	db.SetConnMaxLifetime(5 * time.Minute)

	repo := &MySQLRepo{db: db}
	if err := repo.migrate(); err != nil {
		return nil, fmt.Errorf("migration failed: %w", err)
	}
	return repo, nil
}

func (r *MySQLRepo) migrate() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS events (
			event_id    VARCHAR(36)    PRIMARY KEY,
			name        VARCHAR(255)   NOT NULL,
			venue       VARCHAR(255)   NOT NULL,
			date        VARCHAR(32)    NOT NULL,
			total_seats INT            NOT NULL,
			available   INT            NOT NULL,
			price       DECIMAL(10,2)  NOT NULL,
			created_at  DATETIME       NOT NULL,
			INDEX idx_available (available)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,

		`CREATE TABLE IF NOT EXISTS seats (
			seat_id    VARCHAR(36)  PRIMARY KEY,
			event_id   VARCHAR(36)  NOT NULL,
			seat_no    VARCHAR(16)  NOT NULL,
			status     VARCHAR(16)  NOT NULL DEFAULT 'available',
			created_at DATETIME     NOT NULL,
			FOREIGN KEY (event_id) REFERENCES events(event_id) ON DELETE CASCADE,
			INDEX idx_event_status (event_id, status)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,
	}
	for _, s := range stmts {
		if _, err := r.db.Exec(s); err != nil {
			return err
		}
	}
	return nil
}

func (r *MySQLRepo) SeedData(ctx context.Context) error {
	for _, e := range seedEvents {
		var count int
		_ = r.db.QueryRowContext(ctx, "SELECT COUNT(1) FROM events WHERE event_id=?", e.id).Scan(&count)
		if count > 0 {
			continue
		}

		now := time.Now().UTC()
		_, err := r.db.ExecContext(ctx,
			`INSERT INTO events (event_id,name,venue,date,total_seats,available,price,created_at)
			 VALUES (?,?,?,?,?,?,?,?)`,
			e.id, e.name, e.venue, e.date, e.totalSeats, e.totalSeats, e.price, now,
		)
		if err != nil {
			return fmt.Errorf("seed event %s: %w", e.id, err)
		}

		for i := 1; i <= e.totalSeats; i++ {
			seatID := fmt.Sprintf("%s-seat-%04d", e.id, i)
			seatNo := fmt.Sprintf("S%04d", i)
			_, err := r.db.ExecContext(ctx,
				`INSERT INTO seats (seat_id,event_id,seat_no,status,created_at) VALUES (?,?,?,?,?)`,
				seatID, e.id, seatNo, "available", now,
			)
			if err != nil {
				return fmt.Errorf("seed seat %s: %w", seatID, err)
			}
		}
		log.Printf("Seeded event %s with %d seats", e.id, e.totalSeats)
	}
	return nil
}

func (r *MySQLRepo) ListEvents(ctx context.Context) ([]Event, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT event_id,name,venue,date,total_seats,available,price,created_at FROM events ORDER BY date`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []Event
	for rows.Next() {
		var e Event
		if err := rows.Scan(&e.EventID, &e.Name, &e.Venue, &e.Date,
			&e.TotalSeats, &e.Available, &e.Price, &e.CreatedAt); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	return events, nil
}

func (r *MySQLRepo) GetEvent(ctx context.Context, eventID string) (*Event, error) {
	var e Event
	err := r.db.QueryRowContext(ctx,
		`SELECT event_id,name,venue,date,total_seats,available,price,created_at
		 FROM events WHERE event_id=?`, eventID,
	).Scan(&e.EventID, &e.Name, &e.Venue, &e.Date, &e.TotalSeats, &e.Available, &e.Price, &e.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return &e, err
}

func (r *MySQLRepo) ListSeats(ctx context.Context, eventID string) ([]Seat, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT seat_id,event_id,seat_no,status,created_at FROM seats WHERE event_id=? ORDER BY seat_no`,
		eventID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var seats []Seat
	for rows.Next() {
		var s Seat
		if err := rows.Scan(&s.SeatID, &s.EventID, &s.SeatNo, &s.Status, &s.CreatedAt); err != nil {
			return nil, err
		}
		seats = append(seats, s)
	}
	return seats, nil
}

func (r *MySQLRepo) GetAvailableCount(ctx context.Context, eventID string) (int, error) {
	var count int
	err := r.db.QueryRowContext(ctx,
		`SELECT available FROM events WHERE event_id=?`, eventID,
	).Scan(&count)
	return count, err
}

func (r *MySQLRepo) ReserveSeat(ctx context.Context, eventID, seatID string) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`UPDATE seats SET status='reserved' WHERE seat_id=? AND event_id=? AND status='available'`,
		seatID, eventID,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("seat %s not available", seatID)
	}

	_, err = tx.ExecContext(ctx,
		`UPDATE events SET available=available-1 WHERE event_id=? AND available>0`, eventID)
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (r *MySQLRepo) ReleaseSeat(ctx context.Context, eventID, seatID string) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	_, err = tx.ExecContext(ctx,
		`UPDATE seats SET status='available' WHERE seat_id=? AND event_id=?`, seatID, eventID)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx,
		`UPDATE events SET available=available+1 WHERE event_id=?`, eventID)
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (r *MySQLRepo) ResetInventory(ctx context.Context) error {
	stmts := []string{
		`DROP TABLE IF EXISTS seats`,
		`DROP TABLE IF EXISTS events`,
	}
	for _, s := range stmts {
		if _, err := r.db.Exec(s); err != nil {
			return err
		}
	}
	err := r.migrate()
	if err != nil {
		return err
	}
	return r.SeedData(ctx)
}

func (r *MySQLRepo) Close() error {
	return r.db.Close()
}
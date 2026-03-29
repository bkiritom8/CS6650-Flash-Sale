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

	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(10)
	db.SetConnMaxLifetime(5 * time.Minute)

	repo := &MySQLRepo{db: db}
	if err := repo.migrate(); err != nil {
		return nil, fmt.Errorf("migration failed: %w", err)
	}
	return repo, nil
}

func (r *MySQLRepo) migrate() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS bookings (
			booking_id  VARCHAR(36)  PRIMARY KEY,
			event_id    VARCHAR(36)  NOT NULL,
			seat_id     VARCHAR(64)  NOT NULL,
			customer_id INT          NOT NULL,
			status      VARCHAR(16)  NOT NULL DEFAULT 'confirmed',
			lock_mode   VARCHAR(16)  NOT NULL,
			created_at  DATETIME     NOT NULL,
			INDEX idx_event  (event_id),
			INDEX idx_seat   (event_id, seat_id),
			INDEX idx_status (status)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,

		// Tracks every oversell event for Experiment 1 metrics
		`CREATE TABLE IF NOT EXISTS oversell_events (
			id         BIGINT       AUTO_INCREMENT PRIMARY KEY,
			event_id   VARCHAR(36)  NOT NULL,
			seat_id    VARCHAR(64)  NOT NULL,
			created_at DATETIME     NOT NULL,
			INDEX idx_event (event_id)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,

		// Version table used by optimistic locking
		// Each row tracks the booking version for a (event, seat) pair
		`CREATE TABLE IF NOT EXISTS seat_versions (
			event_id VARCHAR(36)  NOT NULL,
			seat_id  VARCHAR(64)  NOT NULL,
			version  INT          NOT NULL DEFAULT 0,
			status   VARCHAR(16)  NOT NULL DEFAULT 'available',
			PRIMARY KEY (event_id, seat_id)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,
	}
	for _, s := range stmts {
		if _, err := r.db.Exec(s); err != nil {
			return err
		}
	}
	return nil
}

// ── Core booking ──────────────────────────────────────────────────────────────

func (r *MySQLRepo) CreateBooking(ctx context.Context, b *Booking) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO bookings (booking_id,event_id,seat_id,customer_id,status,lock_mode,created_at)
		 VALUES (?,?,?,?,?,?,?)`,
		b.BookingID, b.EventID, b.SeatID, b.CustomerID, b.Status, b.LockMode, b.CreatedAt,
	)
	return err
}

func (r *MySQLRepo) GetBooking(ctx context.Context, bookingID string) (*Booking, error) {
	var b Booking
	err := r.db.QueryRowContext(ctx,
		`SELECT booking_id,event_id,seat_id,customer_id,status,lock_mode,created_at
		 FROM bookings WHERE booking_id=?`, bookingID,
	).Scan(&b.BookingID, &b.EventID, &b.SeatID, &b.CustomerID, &b.Status, &b.LockMode, &b.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return &b, err
}

func (r *MySQLRepo) ListBookingsByEvent(ctx context.Context, eventID string) ([]Booking, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT booking_id,event_id,seat_id,customer_id,status,lock_mode,created_at
		 FROM bookings WHERE event_id=? ORDER BY created_at DESC`, eventID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var bookings []Booking
	for rows.Next() {
		var b Booking
		if err := rows.Scan(&b.BookingID, &b.EventID, &b.SeatID, &b.CustomerID,
			&b.Status, &b.LockMode, &b.CreatedAt); err != nil {
			return nil, err
		}
		bookings = append(bookings, b)
	}
	return bookings, nil
}

func (r *MySQLRepo) CancelBooking(ctx context.Context, bookingID string) error {
	_, err := r.db.ExecContext(ctx,
		`UPDATE bookings SET status='cancelled' WHERE booking_id=?`, bookingID)
	return err
}

// ── No-lock mode ──────────────────────────────────────────────────────────────
// Intentionally unsafe — reads availability then writes without holding a lock.
// Race window between SELECT and INSERT causes oversells.
// This is the Experiment 1 baseline — do NOT fix this behaviour.

func (r *MySQLRepo) CheckAndReserveNoLock(ctx context.Context, eventID, seatID string, b *Booking) error {
	// Check availability (no lock held)
	var status string
	err := r.db.QueryRowContext(ctx,
		`SELECT status FROM seat_versions WHERE event_id=? AND seat_id=?`, eventID, seatID,
	).Scan(&status)

	if err == sql.ErrNoRows {
		// First time seeing this seat — initialise
		_, err = r.db.ExecContext(ctx,
			`INSERT IGNORE INTO seat_versions (event_id,seat_id,version,status) VALUES (?,?,0,'available')`,
			eventID, seatID,
		)
		if err != nil {
			return err
		}
		status = "available"
	} else if err != nil {
		return err
	}

	if status != "available" {
		// Record oversell — seat already taken but we proceed anyway (baseline)
		_, _ = r.db.ExecContext(ctx,
			`INSERT INTO oversell_events (event_id,seat_id,created_at) VALUES (?,?,?)`,
			eventID, seatID, time.Now().UTC(),
		)
	}

	// Write booking regardless — this is the unsafe path
	return r.CreateBooking(ctx, b)
}

// ── Optimistic locking ────────────────────────────────────────────────────────
// Read version → attempt write with version check → retry on mismatch.
// No locks held during processing. Low latency, occasional retries under contention.

func (r *MySQLRepo) CheckAndReserveOptimistic(ctx context.Context, eventID, seatID string, b *Booking, maxRetries int) error {
	for attempt := 0; attempt <= maxRetries; attempt++ {
		var version int
		var status string

		err := r.db.QueryRowContext(ctx,
			`SELECT version, status FROM seat_versions WHERE event_id=? AND seat_id=?`,
			eventID, seatID,
		).Scan(&version, &status)

		if err == sql.ErrNoRows {
			_, err = r.db.ExecContext(ctx,
				`INSERT IGNORE INTO seat_versions (event_id,seat_id,version,status) VALUES (?,?,0,'available')`,
				eventID, seatID,
			)
			if err != nil {
				return err
			}
			version = 0
			status = "available"
		} else if err != nil {
			return err
		}

		if status != "available" {
			return fmt.Errorf("seat %s is not available", seatID)
		}

		// Attempt update — only succeeds if version hasn't changed since we read it
		res, err := r.db.ExecContext(ctx,
			`UPDATE seat_versions SET status='reserved', version=version+1
			 WHERE event_id=? AND seat_id=? AND version=? AND status='available'`,
			eventID, seatID, version,
		)
		if err != nil {
			return err
		}

		n, _ := res.RowsAffected()
		if n > 0 {
			// Version matched — we won the race, create the booking
			return r.CreateBooking(ctx, b)
		}

		// Version changed — someone else booked concurrently, retry
		log.Printf("optimistic conflict on seat %s (attempt %d/%d)", seatID, attempt+1, maxRetries)
		time.Sleep(time.Duration(attempt*10) * time.Millisecond) // simple backoff
	}
	return fmt.Errorf("seat %s: max retries exceeded under contention", seatID)
}

// ── Pessimistic locking ───────────────────────────────────────────────────────
// Acquires SELECT ... FOR UPDATE — holds a row-level lock until transaction commits.
// Guarantees zero oversells. Higher latency under load.

func (r *MySQLRepo) CheckAndReservePessimistic(ctx context.Context, eventID, seatID string, b *Booking) error {
	tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var status string
	err = tx.QueryRowContext(ctx,
		`SELECT status FROM seat_versions WHERE event_id=? AND seat_id=? FOR UPDATE`,
		eventID, seatID,
	).Scan(&status)

	if err == sql.ErrNoRows {
		// Initialise under lock
		_, err = tx.ExecContext(ctx,
			`INSERT INTO seat_versions (event_id,seat_id,version,status) VALUES (?,?,0,'available')
			 ON DUPLICATE KEY UPDATE seat_id=seat_id`,
			eventID, seatID,
		)
		if err != nil {
			return err
		}
		status = "available"
	} else if err != nil {
		return err
	}

	if status != "available" {
		return fmt.Errorf("seat %s is not available", seatID)
	}

	// Mark reserved while holding the lock
	_, err = tx.ExecContext(ctx,
		`UPDATE seat_versions SET status='reserved', version=version+1
		 WHERE event_id=? AND seat_id=?`,
		eventID, seatID,
	)
	if err != nil {
		return err
	}

	_, err = tx.ExecContext(ctx,
		`INSERT INTO bookings (booking_id,event_id,seat_id,customer_id,status,lock_mode,created_at)
		 VALUES (?,?,?,?,?,?,?)`,
		b.BookingID, b.EventID, b.SeatID, b.CustomerID, b.Status, b.LockMode, b.CreatedAt,
	)
	if err != nil {
		return err
	}

	return tx.Commit()
}

// ── Metrics ───────────────────────────────────────────────────────────────────

func (r *MySQLRepo) CountOversells(ctx context.Context, eventID string) (int, error) {
    var count int
    err := r.db.QueryRowContext(ctx,
        `SELECT GREATEST(0, COUNT(*) - 1) 
         FROM bookings 
         WHERE event_id=? AND seat_id='seat-last' AND status='confirmed'`,
        eventID,
    ).Scan(&count)
    return count, err
}

// ── Cleanup ───────────────────────────────────────────────────────────────────

func (r *MySQLRepo) ResetBookings(ctx context.Context) error {
	stmts := []string{
		`DROP TABLE IF EXISTS bookings`,
		`DROP TABLE IF EXISTS oversell_events`,
		`DROP TABLE IF EXISTS seat_versions`,
	}
	for _, s := range stmts {
		if _, err := r.db.ExecContext(ctx, s); err != nil {
			return err
		}
	}
	return r.migrate()
}

func (r *MySQLRepo) Close() error { return r.db.Close() }

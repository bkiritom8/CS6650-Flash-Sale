package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/go-sql-driver/mysql"
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

	// Allow enough connections for 1000 concurrent goroutines.
	db.SetMaxOpenConns(200)
	db.SetMaxIdleConns(50)
	db.SetConnMaxLifetime(5 * time.Minute)

	repo := &MySQLRepo{db: db}
	if err := repo.migrate(); err != nil {
		return nil, fmt.Errorf("migration failed: %w", err)
	}
	return repo, nil
}

func (r *MySQLRepo) migrate() error {
	stmts := []string{
		// Seat state — one row per (event, seat) pair.
		// Experiment runs use unique event_ids so rows never collide.
		`CREATE TABLE IF NOT EXISTS exp1_seat_versions (
			event_id VARCHAR(64)  NOT NULL,
			seat_id  VARCHAR(64)  NOT NULL,
			version  INT          NOT NULL DEFAULT 0,
			status   VARCHAR(16)  NOT NULL DEFAULT 'available',
			PRIMARY KEY (event_id, seat_id)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,

		// One row per booking attempt that reached the write path.
		`CREATE TABLE IF NOT EXISTS exp1_bookings (
			booking_id VARCHAR(36)  PRIMARY KEY,
			event_id   VARCHAR(64)  NOT NULL,
			seat_id    VARCHAR(64)  NOT NULL,
			lock_mode  VARCHAR(16)  NOT NULL,
			created_at DATETIME     NOT NULL,
			INDEX idx_seat (event_id, seat_id)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,

		// Logged whenever no-lock mode detects the seat was already taken.
		`CREATE TABLE IF NOT EXISTS exp1_oversells (
			id         BIGINT       AUTO_INCREMENT PRIMARY KEY,
			event_id   VARCHAR(64)  NOT NULL,
			seat_id    VARCHAR(64)  NOT NULL,
			created_at DATETIME     NOT NULL,
			INDEX idx_seat (event_id, seat_id)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`,
	}
	for _, s := range stmts {
		if _, err := r.db.Exec(s); err != nil {
			return err
		}
	}
	return nil
}

// ── InitSeat ──────────────────────────────────────────────────────────────────

func (r *MySQLRepo) InitSeat(ctx context.Context, eventID, seatID string) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO exp1_seat_versions (event_id, seat_id, version, status)
		 VALUES (?, ?, 0, 'available')`,
		eventID, seatID,
	)
	return err
}

// ── No-lock mode ──────────────────────────────────────────────────────────────
// Read status without a lock, write booking unconditionally.
// The gap between SELECT and INSERT is the race window that causes oversells.

func (r *MySQLRepo) BookNoLock(ctx context.Context, eventID, seatID, bookingID string) (bool, error) {
	var status string
	err := r.db.QueryRowContext(ctx,
		`SELECT status FROM exp1_seat_versions WHERE event_id=? AND seat_id=?`,
		eventID, seatID,
	).Scan(&status)
	if err != nil {
		return false, err
	}

	oversold := status != "available"
	if oversold {
		_, _ = r.db.ExecContext(ctx,
			`INSERT INTO exp1_oversells (event_id, seat_id, created_at) VALUES (?, ?, ?)`,
			eventID, seatID, time.Now().UTC(),
		)
	}

	// Write booking regardless — this is the unsafe baseline.
	_, err = r.db.ExecContext(ctx,
		`INSERT INTO exp1_bookings (booking_id, event_id, seat_id, lock_mode, created_at)
		 VALUES (?, ?, ?, 'none', ?)`,
		bookingID, eventID, seatID, time.Now().UTC(),
	)
	return oversold, err
}

// ── Optimistic locking ────────────────────────────────────────────────────────
// Read version → attempt conditional update → retry on version mismatch.
// No row lock held during processing; low contention overhead, occasional retries.

func (r *MySQLRepo) BookOptimistic(ctx context.Context, eventID, seatID, bookingID string, maxRetries int) error {
	for attempt := 0; attempt <= maxRetries; attempt++ {
		var version int
		var status string

		err := r.db.QueryRowContext(ctx,
			`SELECT version, status FROM exp1_seat_versions WHERE event_id=? AND seat_id=?`,
			eventID, seatID,
		).Scan(&version, &status)
		if err != nil {
			return err
		}
		if status != "available" {
			return fmt.Errorf("seat not available")
		}

		// Only succeeds when our version still matches — guards against concurrent writers.
		res, err := r.db.ExecContext(ctx,
			`UPDATE exp1_seat_versions
			 SET status='reserved', version=version+1
			 WHERE event_id=? AND seat_id=? AND version=? AND status='available'`,
			eventID, seatID, version,
		)
		if err != nil {
			return err
		}

		if n, _ := res.RowsAffected(); n > 0 {
			_, err = r.db.ExecContext(ctx,
				`INSERT INTO exp1_bookings (booking_id, event_id, seat_id, lock_mode, created_at)
				 VALUES (?, ?, ?, 'optimistic', ?)`,
				bookingID, eventID, seatID, time.Now().UTC(),
			)
			return err
		}

		// Version changed — back off and retry.
		time.Sleep(time.Duration(attempt*5) * time.Millisecond)
	}
	return fmt.Errorf("seat not available after %d retries", maxRetries)
}

// ── Pessimistic locking ───────────────────────────────────────────────────────
// SELECT … FOR UPDATE acquires a row-level lock; all other writers queue behind it.
// Zero oversells guaranteed; latency scales linearly with concurrency.

func (r *MySQLRepo) BookPessimistic(ctx context.Context, eventID, seatID, bookingID string) error {
	tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var status string
	err = tx.QueryRowContext(ctx,
		`SELECT status FROM exp1_seat_versions WHERE event_id=? AND seat_id=? FOR UPDATE`,
		eventID, seatID,
	).Scan(&status)
	if err != nil {
		return err
	}
	if status != "available" {
		return fmt.Errorf("seat not available")
	}

	if _, err = tx.ExecContext(ctx,
		`UPDATE exp1_seat_versions SET status='reserved', version=version+1
		 WHERE event_id=? AND seat_id=?`, eventID, seatID); err != nil {
		return err
	}

	if _, err = tx.ExecContext(ctx,
		`INSERT INTO exp1_bookings (booking_id, event_id, seat_id, lock_mode, created_at)
		 VALUES (?, ?, ?, 'pessimistic', ?)`,
		bookingID, eventID, seatID, time.Now().UTC()); err != nil {
		return err
	}

	return tx.Commit()
}

// ── Metrics ───────────────────────────────────────────────────────────────────

func (r *MySQLRepo) CountBookings(ctx context.Context, eventID, seatID string) (int, error) {
	var n int
	err := r.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM exp1_bookings WHERE event_id=? AND seat_id=?`,
		eventID, seatID,
	).Scan(&n)
	return n, err
}

func (r *MySQLRepo) CountOversells(ctx context.Context, eventID, seatID string) (int, error) {
	var n int
	err := r.db.QueryRowContext(ctx,
		`SELECT GREATEST(0, COUNT(*) - 1) FROM exp1_bookings WHERE event_id=? AND seat_id=?`,
		eventID, seatID,
	).Scan(&n)
	return n, err
}

// ── Cleanup ───────────────────────────────────────────────────────────────────

func (r *MySQLRepo) Cleanup(ctx context.Context, eventID, seatID string) error {
	stmts := []string{
		`DELETE FROM exp1_bookings  WHERE event_id=? AND seat_id=?`,
		`DELETE FROM exp1_oversells WHERE event_id=? AND seat_id=?`,
		`DELETE FROM exp1_seat_versions WHERE event_id=? AND seat_id=?`,
	}
	for _, s := range stmts {
		if _, err := r.db.ExecContext(ctx, s, eventID, seatID); err != nil {
			return err
		}
	}
	return nil
}

func (r *MySQLRepo) Close() error { return r.db.Close() }

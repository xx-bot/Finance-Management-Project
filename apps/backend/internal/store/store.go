package store

import (
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"pocketledger/backend/internal/auth"
	"pocketledger/backend/internal/domain"
)

var ErrNotFound = errors.New("record not found")
var ErrConflict = errors.New("record already exists")

//go:embed migrations/*.sql
var migrations embed.FS

type Store struct{ Pool *pgxpool.Pool }

func Open(ctx context.Context, url string) (*Store, error) {
	config, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("invalid database configuration")
	}
	config.MaxConns = 10
	config.MinConns = 1
	config.ConnConfig.ConnectTimeout = 5 * time.Second
	config.ConnConfig.RuntimeParams["statement_timeout"] = "15000"
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, fmt.Errorf("create database pool: %w", err)
	}
	s := &Store{pool}
	if err = pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("connect to PostgreSQL: %w", err)
	}
	return s, nil
}

func (s *Store) Migrate(ctx context.Context) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(709821241)"); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, "CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, checksum TEXT NOT NULL, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())"); err != nil {
		return err
	}
	entries, err := migrations.ReadDir("migrations")
	if err != nil {
		return err
	}
	for _, entry := range entries {
		data, err := migrations.ReadFile("migrations/" + entry.Name())
		if err != nil {
			return err
		}
		sum := sha256.Sum256(data)
		checksum := hex.EncodeToString(sum[:])
		var existing string
		err = tx.QueryRow(ctx, "SELECT checksum FROM schema_migrations WHERE version=$1", entry.Name()).Scan(&existing)
		if err == nil {
			if existing != checksum {
				return fmt.Errorf("applied migration %s was changed", entry.Name())
			}
			continue
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if _, err = tx.Exec(ctx, string(data)); err != nil {
			return fmt.Errorf("migration %s: %w", entry.Name(), err)
		}
		if _, err = tx.Exec(ctx, "INSERT INTO schema_migrations(version,checksum) VALUES($1,$2)", entry.Name(), checksum); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func translate(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	var pg *pgconn.PgError
	if errors.As(err, &pg) && pg.Code == "23505" {
		return ErrConflict
	}
	return err
}

func (s *Store) CreateAccount(ctx context.Context, user auth.User, password, tokenHash []byte, expires time.Time) (auth.User, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return user, err
	}
	defer tx.Rollback(ctx)
	err = tx.QueryRow(ctx, "INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3) RETURNING created_at", user.ID, user.Email, password).Scan(&user.CreatedAt)
	if err != nil {
		return user, translate(err)
	}
	if _, err = tx.Exec(ctx, "INSERT INTO sessions(token_hash,user_id,expires_at) VALUES($1,$2,$3)", tokenHash, user.ID, expires); err != nil {
		return user, err
	}
	for _, b := range []domain.Budget{{Currency: "IDR", AmountMinor: 300000000}, {Currency: "MYR", AmountMinor: 200000}, {Currency: "USD", AmountMinor: 150000}} {
		if _, err = tx.Exec(ctx, "INSERT INTO budgets(user_id,currency,amount_minor) VALUES($1,$2,$3)", user.ID, b.Currency, b.AmountMinor); err != nil {
			return user, err
		}
	}
	return user, tx.Commit(ctx)
}

func (s *Store) UserByEmail(ctx context.Context, email string) (auth.User, []byte, error) {
	var user auth.User
	var hash []byte
	err := s.Pool.QueryRow(ctx, "SELECT id::text,email,password_hash,created_at FROM users WHERE email=$1", email).Scan(&user.ID, &user.Email, &hash, &user.CreatedAt)
	return user, hash, translate(err)
}
func (s *Store) AddSession(ctx context.Context, userID string, hash []byte, expires time.Time) error {
	_, err := s.Pool.Exec(ctx, "WITH expired AS (DELETE FROM sessions WHERE user_id=$1 AND expires_at <= now()) INSERT INTO sessions(token_hash,user_id,expires_at) VALUES($2,$1,$3)", userID, hash, expires)
	return err
}
func (s *Store) Authenticate(ctx context.Context, hash []byte) (auth.User, error) {
	var user auth.User
	err := s.Pool.QueryRow(ctx, "SELECT u.id::text,u.email,u.created_at FROM users u JOIN sessions s ON s.user_id=u.id WHERE s.token_hash=$1 AND s.expires_at>now()", hash).Scan(&user.ID, &user.Email, &user.CreatedAt)
	return user, translate(err)
}
func (s *Store) Logout(ctx context.Context, hash []byte) error {
	_, err := s.Pool.Exec(ctx, "DELETE FROM sessions WHERE token_hash=$1", hash)
	return err
}

func (s *Store) SaveExpense(ctx context.Context, user string, e domain.Expense) (domain.Expense, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return e, err
	}
	defer tx.Rollback(ctx)
	adjustments, err := json.Marshal(e.Adjustments)
	if err != nil {
		return e, err
	}
	err = tx.QueryRow(ctx, `INSERT INTO expenses(user_id,id,merchant,receipt_date,currency,total_minor,category,adjustments,note,status)
	VALUES($1,$2,$3,$4::date,$5,$6,$7,$8,$9,$10) ON CONFLICT(user_id,id) DO UPDATE SET merchant=EXCLUDED.merchant,
	receipt_date=EXCLUDED.receipt_date,currency=EXCLUDED.currency,total_minor=EXCLUDED.total_minor,category=EXCLUDED.category,
	adjustments=EXCLUDED.adjustments,note=EXCLUDED.note,status=EXCLUDED.status,updated_at=now() RETURNING updated_at`,
		user, e.ID, e.Merchant, e.Date, e.Currency, e.TotalMinor, e.Category, adjustments, e.Note, e.Status).Scan(&e.UpdatedAt)
	if err != nil {
		return e, err
	}
	if _, err = tx.Exec(ctx, "DELETE FROM expense_items WHERE user_id=$1 AND expense_id=$2", user, e.ID); err != nil {
		return e, err
	}
	for position, line := range e.Lines {
		sub, err := json.Marshal(line.SubItems)
		if err != nil {
			return e, err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO expense_items(user_id,expense_id,position,description,amount_minor,category,quantity,unit_price,sub_items) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
			user, e.ID, position, line.Description, line.AmountMinor, line.Category, line.Quantity, line.UnitPrice, sub); err != nil {
			return e, err
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return e, err
	}
	return e, nil
}

const expenseColumns = `e.id,e.merchant,to_char(e.receipt_date,'YYYY-MM-DD'),e.currency,e.total_minor,e.category,e.adjustments,e.note,e.status,e.updated_at,
 COALESCE((SELECT jsonb_agg(jsonb_build_object('description',i.description,'amount_minor',i.amount_minor,'category',i.category,'quantity',i.quantity,'unit_price',i.unit_price,'sub_items',i.sub_items) ORDER BY i.position)
 FROM expense_items i WHERE i.user_id=e.user_id AND i.expense_id=e.id),'[]'::jsonb)`

func scanExpense(row pgx.Row) (domain.Expense, error) {
	var e domain.Expense
	var adjustments, lines []byte
	err := row.Scan(&e.ID, &e.Merchant, &e.Date, &e.Currency, &e.TotalMinor, &e.Category, &adjustments, &e.Note, &e.Status, &e.UpdatedAt, &lines)
	if err != nil {
		return e, translate(err)
	}
	if err = json.Unmarshal(adjustments, &e.Adjustments); err != nil {
		return e, err
	}
	if err = json.Unmarshal(lines, &e.Lines); err != nil {
		return e, err
	}
	return e, nil
}
func (s *Store) Expense(ctx context.Context, user, id string) (domain.Expense, error) {
	return scanExpense(s.Pool.QueryRow(ctx, "SELECT "+expenseColumns+" FROM expenses e WHERE e.user_id=$1 AND e.id=$2", user, id))
}
func (s *Store) Expenses(ctx context.Context, user, currency, month string, limit, offset int) (domain.ExpensePage, error) {
	page := domain.ExpensePage{Expenses: []domain.Expense{}, Limit: limit, Offset: offset}
	rows, err := s.Pool.Query(ctx, "SELECT "+expenseColumns+` FROM expenses e WHERE e.user_id=$1 AND ($2='' OR e.currency=$2)
	 AND ($3='' OR to_char(e.receipt_date,'YYYY-MM')=$3) ORDER BY e.receipt_date DESC,e.id DESC LIMIT $4 OFFSET $5`, user, currency, month, limit+1, offset)
	if err != nil {
		return page, err
	}
	defer rows.Close()
	for rows.Next() {
		e, err := scanExpense(rows)
		if err != nil {
			return page, err
		}
		page.Expenses = append(page.Expenses, e)
	}
	if err = rows.Err(); err != nil {
		return page, err
	}
	if len(page.Expenses) > limit {
		page.HasMore = true
		page.Expenses = page.Expenses[:limit]
	}
	return page, nil
}
func (s *Store) DeleteExpense(ctx context.Context, user, id string) error {
	result, err := s.Pool.Exec(ctx, "DELETE FROM expenses WHERE user_id=$1 AND id=$2", user, id)
	if err != nil {
		return err
	}
	if result.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
func (s *Store) Budgets(ctx context.Context, user string) ([]domain.Budget, error) {
	result := []domain.Budget{}
	rows, err := s.Pool.Query(ctx, "SELECT currency,amount_minor FROM budgets WHERE user_id=$1 ORDER BY currency", user)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var b domain.Budget
		if err = rows.Scan(&b.Currency, &b.AmountMinor); err != nil {
			return nil, err
		}
		result = append(result, b)
	}
	return result, rows.Err()
}
func (s *Store) SaveBudget(ctx context.Context, user string, b domain.Budget) error {
	_, err := s.Pool.Exec(ctx, "INSERT INTO budgets(user_id,currency,amount_minor) VALUES($1,$2,$3) ON CONFLICT(user_id,currency) DO UPDATE SET amount_minor=EXCLUDED.amount_minor", user, b.Currency, b.AmountMinor)
	return err
}

type Summary struct {
	Currency       string           `json:"currency"`
	Month          string           `json:"month"`
	TotalMinor     int64            `json:"total_minor"`
	ExpenseCount   int              `json:"expense_count"`
	BudgetMinor    int64            `json:"budget_minor"`
	CategoryTotals map[string]int64 `json:"category_totals"`
	DailyTotals    []int64          `json:"daily_totals"`
}

func (s *Store) Summary(ctx context.Context, user, currency, month string) (Summary, error) {
	date, _ := time.Parse("2006-01", month)
	days := date.AddDate(0, 1, -1).Day()
	result := Summary{Currency: currency, Month: month, CategoryTotals: map[string]int64{}, DailyTotals: make([]int64, days)}
	// Use a repeatable-read snapshot so totals and budget come from one view of the ledger.
	tx, err := s.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return result, err
	}
	defer tx.Rollback(ctx)
	err = tx.QueryRow(ctx, "SELECT amount_minor FROM budgets WHERE user_id=$1 AND currency=$2", user, currency).Scan(&result.BudgetMinor)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return result, err
	}
	rows, err := tx.Query(ctx, "SELECT "+expenseColumns+" FROM expenses e WHERE e.user_id=$1 AND e.currency=$2 AND to_char(e.receipt_date,'YYYY-MM')=$3", user, currency, month)
	if err != nil {
		return result, err
	}
	for rows.Next() {
		e, err := scanExpense(rows)
		if err != nil {
			rows.Close()
			return result, err
		}
		if result.TotalMinor > domain.MaxMoney-e.TotalMinor {
			rows.Close()
			return result, fmt.Errorf("monthly total exceeds supported range")
		}
		result.TotalMinor += e.TotalMinor
		result.ExpenseCount++
		d, _ := time.Parse(time.DateOnly, e.Date)
		result.DailyTotals[d.Day()-1] += e.TotalMinor
		for category, amount := range e.Allocations() {
			result.CategoryTotals[category] += amount
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return result, err
	}
	return result, tx.Commit(ctx)
}

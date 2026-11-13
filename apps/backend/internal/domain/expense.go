package domain

import (
	"fmt"
	"math/big"
	"regexp"
	"sort"
	"strings"
	"time"
)

const MaxMoney int64 = 9007199254740991

type Category struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

var Categories = []Category{{"groceries", "Groceries"}, {"dining", "Food & drinks"}, {"transport", "Transport"}, {"shopping", "Shopping"}, {"household", "Home & bills"}, {"health", "Health"}, {"education", "Learning"}, {"other", "Other"}}

type Expense struct {
	ID          string        `json:"id"`
	Merchant    string        `json:"merchant"`
	Date        string        `json:"date"`
	Currency    string        `json:"currency"`
	TotalMinor  int64         `json:"total_minor"`
	Category    string        `json:"category"`
	Lines       []ExpenseLine `json:"lines"`
	Adjustments []Adjustment  `json:"adjustments"`
	ImagePath   *string       `json:"image_path"` // Device-local paths are never stored by the server.
	Note        string        `json:"note"`
	Status      string        `json:"status"`
	UpdatedAt   time.Time     `json:"updated_at,omitempty"`
}

type ExpenseLine struct {
	Description string        `json:"description"`
	AmountMinor int64         `json:"amount_minor"`
	Category    string        `json:"category"`
	Quantity    *string       `json:"quantity"`
	UnitPrice   *string       `json:"unit_price"`
	SubItems    []ReceiptItem `json:"sub_items"`
}

type Adjustment struct {
	Label       string `json:"label"`
	AmountMinor int64  `json:"amount_minor"`
}
type Budget struct {
	Currency    string `json:"currency"`
	AmountMinor int64  `json:"amount_minor"`
}
type ExpensePage struct {
	Expenses []Expense `json:"expenses"`
	Limit    int       `json:"limit"`
	Offset   int       `json:"offset"`
	HasMore  bool      `json:"has_more"`
}

func (e *Expense) UnmarshalJSON(data []byte) error {
	if err := nonNull(data, "id", "merchant", "date", "currency", "total_minor", "category", "lines"); err != nil {
		return err
	}
	type plain Expense
	return DecodeJSON(data, (*plain)(e))
}
func (line *ExpenseLine) UnmarshalJSON(data []byte) error {
	if err := nonNull(data, "description", "amount_minor", "category"); err != nil {
		return err
	}
	type plain ExpenseLine
	return DecodeJSON(data, (*plain)(line))
}
func (a *Adjustment) UnmarshalJSON(data []byte) error {
	if err := nonNull(data, "label", "amount_minor"); err != nil {
		return err
	}
	type plain Adjustment
	return DecodeJSON(data, (*plain)(a))
}

var idPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

func ValidID(id string) bool          { return idPattern.MatchString(id) }
func ValidCurrency(value string) bool { return value == "IDR" || value == "MYR" || value == "USD" }
func ValidCategory(value string) bool {
	for _, c := range Categories {
		if c.ID == value {
			return true
		}
	}
	return false
}

func DateOnly(value string) (string, error) {
	for _, layout := range []string{time.DateOnly, time.RFC3339Nano, "2006-01-02T15:04:05.999999999"} {
		if date, err := time.Parse(layout, value); err == nil && date.Year() >= 1 && date.Year() <= 9999 {
			return date.Format(time.DateOnly), nil
		}
	}
	return "", fmt.Errorf("date must be YYYY-MM-DD or an ISO 8601 date-time")
}

func (e *Expense) Validate() error {
	if !ValidID(e.ID) {
		return fmt.Errorf("id must contain 1-128 letters, digits, underscores or hyphens")
	}
	e.Merchant = strings.TrimSpace(e.Merchant)
	if e.Merchant == "" || len(e.Merchant) > 300 {
		return fmt.Errorf("merchant must contain 1-300 bytes")
	}
	date, err := DateOnly(e.Date)
	if err != nil {
		return err
	}
	e.Date = date
	if !ValidCurrency(e.Currency) {
		return fmt.Errorf("currency must be IDR, MYR or USD")
	}
	if !ValidCategory(e.Category) {
		return fmt.Errorf("unknown expense category")
	}
	if e.TotalMinor < 0 || e.TotalMinor > MaxMoney {
		return fmt.Errorf("total_minor is outside the supported range")
	}
	if e.Lines == nil || len(e.Lines) > 500 || len(e.Adjustments) > 100 {
		return fmt.Errorf("lines must be an array with at most 500 entries; at most 100 adjustments are allowed")
	}
	if e.Adjustments == nil {
		e.Adjustments = []Adjustment{}
	}
	var subtotal int64
	count := 0
	for i := range e.Lines {
		line := &e.Lines[i]
		line.Description = strings.TrimSpace(line.Description)
		if line.Description == "" || len(line.Description) > 2000 || !ValidCategory(line.Category) {
			return fmt.Errorf("invalid item description or category")
		}
		if line.AmountMinor < 0 || line.AmountMinor > MaxMoney {
			return fmt.Errorf("invalid item amount_minor")
		}
		for _, text := range []*string{line.Quantity, line.UnitPrice} {
			if text != nil && len(*text) > 200 {
				return fmt.Errorf("quantity or unit price is too long")
			}
		}
		if line.SubItems == nil {
			line.SubItems = []ReceiptItem{}
		}
		if err := validateItems(line.SubItems, 0, &count, false); err != nil {
			return err
		}
		subtotal += line.AmountMinor
	}
	for _, a := range e.Adjustments {
		if strings.TrimSpace(a.Label) == "" || len(a.Label) > 100 || a.AmountMinor < -MaxMoney || a.AmountMinor > MaxMoney {
			return fmt.Errorf("invalid adjustment")
		}
		subtotal += a.AmountMinor
	}
	if len(e.Note) > 5000 {
		return fmt.Errorf("note is too long")
	}
	if e.Status == "" {
		e.Status = "verified"
	}
	if e.Status != "verified" && e.Status != "reviewed_difference" {
		return fmt.Errorf("status must be verified or reviewed_difference")
	}
	if len(e.Lines) > 0 && subtotal != e.TotalMinor && e.Status != "reviewed_difference" {
		return fmt.Errorf("items and adjustments differ from the final total; review the difference before saving")
	}
	e.ImagePath = nil
	return nil
}

// Allocations mirrors the Flutter largest-remainder rule, including its tie order.
func (e Expense) Allocations() map[string]int64 {
	weights := map[string]int64{}
	var subtotal int64
	for _, line := range e.Lines {
		weights[line.Category] += line.AmountMinor
		subtotal += line.AmountMinor
	}
	if subtotal == 0 {
		return map[string]int64{e.Category: e.TotalMinor}
	}
	type part struct {
		category  string
		remainder *big.Int
		order     int
	}
	parts := []part{}
	result := map[string]int64{}
	remaining := e.TotalMinor
	for order, category := range Categories {
		weight, ok := weights[category.ID]
		if !ok {
			continue
		}
		product := new(big.Int).Mul(big.NewInt(e.TotalMinor), big.NewInt(weight))
		quotient, remainder := new(big.Int), new(big.Int)
		quotient.QuoRem(product, big.NewInt(subtotal), remainder)
		result[category.ID] = quotient.Int64()
		remaining -= quotient.Int64()
		parts = append(parts, part{category.ID, remainder, order})
	}
	sort.Slice(parts, func(i, j int) bool {
		c := parts[i].remainder.Cmp(parts[j].remainder)
		if c == 0 {
			return parts[i].order < parts[j].order
		}
		return c > 0
	})
	for i := int64(0); i < remaining; i++ {
		result[parts[i].category]++
	}
	return result
}

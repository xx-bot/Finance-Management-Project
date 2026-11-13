package domain

import (
	"encoding/json"
	"strings"
	"testing"
)

func sampleExpense() Expense {
	return Expense{ID: "receipt-1", Merchant: "Corner shop", Date: "2026-11-12T00:00:00.000", Currency: "MYR", TotalMinor: 1001, Category: "groceries",
		Lines: []ExpenseLine{{Description: "A", AmountMinor: 500, Category: "groceries"}, {Description: "B", AmountMinor: 500, Category: "dining"}}, Adjustments: []Adjustment{{Label: "Rounding", AmountMinor: 1}}, Status: "verified"}
}

func TestReceiptContract(t *testing.T) {
	valid := `{"merchant":"Corner Cafe","category":"dining","items":[{"category":"dining","description":"Coffee","quantity":"1x","unit_price":null,"line_total":"20.000","sub_items":[]}],"total":"20.000"}`
	r, err := ParseReceipt([]byte(valid))
	if err != nil {
		t.Fatal(err)
	}
	if *r.Total != "20.000" || *r.Items[0].Quantity != "1x" || *r.Merchant != "Corner Cafe" || r.Category != "dining" || r.Items[0].Category != "dining" {
		t.Fatal("printed values were changed")
	}
	for _, body := range []string{valid + valid, `{"items":[],"total":12}`, `{"items":null,"total":null}`, `{"items":[]}`, `{"items":[{"description":"x"}],"total":null}`, `{"items":[],"total":null,"extra":1}`} {
		if _, err := ParseReceipt([]byte(body)); err == nil {
			t.Errorf("accepted invalid receipt: %s", body)
		}
	}
	for _, body := range []string{
		strings.Replace(valid, `"merchant":"Corner Cafe"`, `"merchant":123`, 1),
		strings.Replace(valid, `"category":"dining"`, `"category":"invented"`, 1),
		strings.ReplaceAll(valid, `"category":"dining"`, `"category":null`),
		strings.Replace(valid, `"category":"dining",`, "", 1),
		strings.Replace(valid, `"items":[{"category":"dining",`, `"items":[{`, 1),
		strings.Replace(valid, `"sub_items":[]`, `"sub_items":[{"description":"Extra","quantity":null,"unit_price":null,"line_total":null,"category":"invented","sub_items":[]}]`, 1),
	} {
		if _, err := ParseReceipt([]byte(body)); err == nil {
			t.Errorf("accepted invalid metadata: %s", body)
		}
	}
	if _, err := ParseReceipt([]byte(`{"merchant":null,"category":"other","items":[],"total":null}`)); err != nil {
		t.Fatal(err)
	}
}

func TestSavedSubitemsRemainCompatible(t *testing.T) {
	// Old expenses have no subitem category; new reviewed ones can retain suggestions.
	for _, category := range []string{"", "dining"} {
		e := sampleExpense()
		e.Lines[0].SubItems = []ReceiptItem{{Category: category, SubItems: []ReceiptItem{}}}
		data, _ := json.Marshal(e)
		var out Expense
		if err := DecodeJSON(data, &out); err != nil {
			t.Fatal(err)
		}
		if err := out.Validate(); err != nil {
			t.Fatal(err)
		}
		if out.Lines[0].SubItems[0].Category != category {
			t.Fatal("subitem category changed")
		}
	}
}
func TestJSONBounds(t *testing.T) {
	var out any
	if err := DecodeJSON([]byte(strings.Repeat("[", 40)+"0"+strings.Repeat("]", 40)), &out); err == nil {
		t.Fatal("accepted excessive depth")
	}
}
func TestReviewedExpense(t *testing.T) {
	e := sampleExpense()
	if err := e.Validate(); err != nil {
		t.Fatal(err)
	}
	if e.Date != "2026-11-12" {
		t.Fatalf("date=%s", e.Date)
	}
	e.TotalMinor = 1100
	if err := e.Validate(); err == nil {
		t.Fatal("accepted unreviewed discrepancy")
	}
	e.Status = "reviewed_difference"
	if err := e.Validate(); err != nil {
		t.Fatal(err)
	}
	e.TotalMinor = -1
	if err := e.Validate(); err == nil {
		t.Fatal("accepted negative total")
	}
}
func TestAllocationMatchesPaidTotal(t *testing.T) {
	e := sampleExpense()
	if err := e.Validate(); err != nil {
		t.Fatal(err)
	}
	a := e.Allocations()
	if a["groceries"] != 501 || a["dining"] != 500 {
		t.Fatalf("allocation=%v", a)
	}
	e.TotalMinor = MaxMoney
	e.Lines[0].AmountMinor = MaxMoney
	e.Lines[1].AmountMinor = MaxMoney - 1
	a = e.Allocations()
	if a["groceries"]+a["dining"] != MaxMoney {
		t.Fatal("large allocations overflowed")
	}
}
func TestNullAndFractionalAmountsRejected(t *testing.T) {
	body := `{"id":"one","merchant":"Shop","date":"2026-11-12","currency":"USD","total_minor":null,"category":"other","lines":[]}`
	var e Expense
	if err := DecodeJSON([]byte(body), &e); err == nil {
		t.Fatal("accepted null total")
	}
	body = strings.Replace(body, "null", "12.34", 1)
	if err := DecodeJSON([]byte(body), &e); err == nil {
		t.Fatal("accepted fractional minor amount")
	}
	body = strings.Replace(body, "12.34", "0", 1)
	if err := DecodeJSON([]byte(body), &e); err != nil {
		t.Fatal(err)
	}
	if err := e.Validate(); err != nil {
		t.Fatal(err)
	}
}
func TestExpenseRoundTrip(t *testing.T) {
	e := sampleExpense()
	path := "/private/phone/photo.jpg"
	e.ImagePath = &path
	if err := e.Validate(); err != nil {
		t.Fatal(err)
	}
	if e.ImagePath != nil {
		t.Fatal("retained device-local path")
	}
	data, _ := json.Marshal(e)
	var out Expense
	if err := DecodeJSON(data, &out); err != nil {
		t.Fatal(err)
	}
	if err := out.Validate(); err != nil {
		t.Fatal(err)
	}
	if out.TotalMinor != 1001 || len(out.Lines) != 2 {
		t.Fatal("round trip changed expense")
	}
}

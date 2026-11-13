package domain

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
)

// Receipt preserves printed values and adds category suggestions for user review.
// Extraction never guesses currency or prices.
type Receipt struct {
	Merchant *string       `json:"merchant"`
	Category string        `json:"category"`
	Items    []ReceiptItem `json:"items"`
	Total    *string       `json:"total"`
}

type ReceiptItem struct {
	// Optional when reading subitems from expenses saved before classification existed.
	Category    string        `json:"category,omitempty"`
	Description *string       `json:"description"`
	Quantity    *string       `json:"quantity"`
	UnitPrice   *string       `json:"unit_price"`
	LineTotal   *string       `json:"line_total"`
	SubItems    []ReceiptItem `json:"sub_items"`
}

func DecodeJSON(data []byte, target any) error {
	if err := checkJSONDepth(data); err != nil {
		return err
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(target); err != nil {
		return fmt.Errorf("invalid JSON fields or values")
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return fmt.Errorf("expected exactly one JSON object")
	}
	return nil
}

func checkJSONDepth(data []byte) error {
	d := json.NewDecoder(bytes.NewReader(data))
	depth := 0
	for {
		token, err := d.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("invalid JSON")
		}
		if delimiter, ok := token.(json.Delim); ok {
			switch delimiter {
			case '{', '[':
				depth++
			case '}', ']':
				depth--
			}
			if depth > 32 {
				return fmt.Errorf("JSON is nested too deeply")
			}
		}
	}
	return nil
}

func nonNull(data []byte, keys ...string) error {
	if err := required(data, keys...); err != nil {
		return err
	}
	var raw map[string]json.RawMessage
	_ = json.Unmarshal(data, &raw)
	for _, key := range keys {
		if bytes.Equal(bytes.TrimSpace(raw[key]), []byte("null")) {
			return fmt.Errorf("%s cannot be null", key)
		}
	}
	return nil
}

func required(data []byte, keys ...string) error {
	var raw map[string]json.RawMessage
	if json.Unmarshal(data, &raw) != nil || raw == nil {
		return fmt.Errorf("expected a JSON object")
	}
	for _, key := range keys {
		if _, ok := raw[key]; !ok {
			return fmt.Errorf("missing required field %s", key)
		}
	}
	return nil
}

func (item *ReceiptItem) UnmarshalJSON(data []byte) error {
	if err := required(data, "description", "quantity", "unit_price", "line_total", "sub_items"); err != nil {
		return err
	}
	type plain ReceiptItem
	if err := DecodeJSON(data, (*plain)(item)); err != nil {
		return err
	}
	if item.SubItems == nil {
		return fmt.Errorf("sub_items must be an array")
	}
	return nil
}

func ParseReceipt(data []byte) (Receipt, error) {
	var receipt Receipt
	if err := required(data, "merchant", "category", "items", "total"); err != nil {
		return receipt, err
	}
	if err := DecodeJSON(data, &receipt); err != nil {
		return receipt, err
	}
	if receipt.Items == nil {
		return receipt, fmt.Errorf("items must be an array")
	}
	if receipt.Merchant != nil && len(*receipt.Merchant) > 2000 {
		return receipt, fmt.Errorf("merchant is too long")
	}
	if !ValidCategory(receipt.Category) {
		return receipt, fmt.Errorf("unknown receipt category")
	}
	if receipt.Total != nil && len(*receipt.Total) > 200 {
		return receipt, fmt.Errorf("total is too long")
	}
	count := 0
	if err := validateItems(receipt.Items, 0, &count, true); err != nil {
		return receipt, err
	}
	return receipt, nil
}

func validateItems(items []ReceiptItem, depth int, count *int, requireCategories bool) error {
	if depth > 8 {
		return fmt.Errorf("excessive subitem depth")
	}
	for _, item := range items {
		if (requireCategories || item.Category != "") && !ValidCategory(item.Category) {
			return fmt.Errorf("unknown item category")
		}
		*count++
		if *count > 1000 {
			return fmt.Errorf("too many receipt items")
		}
		for _, text := range []*string{item.Description, item.Quantity, item.UnitPrice, item.LineTotal} {
			if text != nil && len(*text) > 2000 {
				return fmt.Errorf("receipt field is too long")
			}
		}
		if item.SubItems == nil {
			return fmt.Errorf("sub_items must be an array")
		}
		if err := validateItems(item.SubItems, depth+1, count, requireCategories); err != nil {
			return err
		}
	}
	return nil
}

// ReceiptSchema mirrors receipt_schema(include_metadata=True) in the Python package.
func ReceiptSchema() map[string]any {
	categories := make([]string, len(Categories))
	for i, category := range Categories {
		categories[i] = category.ID
	}
	categorySchema := map[string]any{"type": "string", "enum": categories}
	var item func(int) map[string]any
	item = func(depth int) map[string]any {
		child := map[string]any{"type": "array", "items": map[string]any{"type": "object"}, "maxItems": 0}
		if depth > 0 {
			child = map[string]any{"type": "array", "items": item(depth - 1)}
		}
		props := map[string]any{"sub_items": child, "category": categorySchema}
		for _, key := range []string{"description", "quantity", "unit_price", "line_total"} {
			props[key] = map[string]any{"anyOf": []any{map[string]any{"type": "string"}, map[string]any{"type": "null"}}}
		}
		return map[string]any{"type": "object", "properties": props, "required": []string{"description", "quantity", "unit_price", "line_total", "sub_items", "category"}, "additionalProperties": false}
	}
	nullableText := map[string]any{"anyOf": []any{map[string]any{"type": "string"}, map[string]any{"type": "null"}}}
	return map[string]any{"type": "object", "properties": map[string]any{
		"merchant": nullableText, "category": categorySchema,
		"items": map[string]any{"type": "array", "items": item(3)}, "total": nullableText,
	}, "required": []string{"merchant", "category", "items", "total"}, "additionalProperties": false}
}

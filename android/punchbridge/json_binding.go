package libbox

import (
	"encoding/json"
	"errors"
	"io"
	"strings"
)

// Native adapters and bindings ship together. Unknown fields, non-objects,
// and trailing values are contract drift, never forward compatibility.
func decodeOpenRungObject(raw string, target any) error {
	if !strings.HasPrefix(strings.TrimSpace(raw), "{") {
		return errors.New("JSON object required")
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return errors.New("trailing JSON data")
	}
	return nil
}

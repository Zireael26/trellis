// Red fixture: every construct here must produce at least one anti-slop finding.
// One pattern per function, so inverting a rule breaks this file's expectation.
package fixtures

import (
	"encoding/json"
	"reflect"
)

// Widget is the named type the slop below refuses to commit to.
type Widget struct {
	Name string
}

// go-empty-interface: the contract accepts anything and proves nothing.
func Store(payload interface{}) error {
	return json.Unmarshal([]byte("{}"), &payload)
}

// go-empty-interface: `any` in signature position is the same discard, spelled newer.
func Widen(v any) string {
	return v.(Widget).Name
}

// go-unchecked-assert / forcetypeassert: panics instead of reporting the mismatch.
func WidgetName(raw any) string {
	return raw.(Widget).Name
}

// go-reflect: reads the shape at runtime instead of naming it in the signature.
func KindOf(payload any) string {
	return reflect.TypeOf(payload).Kind().String()
}

// errcheck: the marshalling error is dropped on the floor.
func StoreAndForget(w Widget) {
	json.Marshal(w)
}

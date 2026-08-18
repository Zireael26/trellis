// Green fixture: idiomatic evidence-preserving Go. Must produce zero findings.
package fixtures

import (
	"encoding/json"
	"fmt"
)

// Config is the parsed shape, named once at the boundary that produces it.
type Config struct {
	Endpoint string `json:"endpoint"`
	Retries  int    `json:"retries"`
}

// ParseConfig parses an untrusted payload at its I/O boundary into a named type.
func ParseConfig(raw []byte) (Config, error) {
	var cfg Config
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}
	return cfg, nil
}

// Event is a real seam: a behavioural interface, not an empty one.
type Event interface {
	Topic() string
}

// Deploy is one implementation of that seam.
type Deploy struct {
	Ref string
}

// Topic satisfies Event.
func (d Deploy) Topic() string { return "deploy" }

// DeployRef reports the mismatch instead of panicking on it.
func DeployRef(e Event) (string, error) {
	d, ok := e.(Deploy)
	if !ok {
		return "", fmt.Errorf("expected Deploy, got %s", e.Topic())
	}
	return d.Ref, nil
}

// Describe names every shape it handles.
func Describe(e Event) string {
	switch ev := e.(type) {
	case Deploy:
		return "deploy " + ev.Ref
	default:
		return e.Topic()
	}
}

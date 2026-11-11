package shapes_test

import (
	"testing"

	"example.com/shapes"
)

func pi() float64 { return 3 }

func TestNewCircle(t *testing.T) {
	_ = shapes.NewCircle(pi())
}

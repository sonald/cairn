package shapes

type Shape interface {
	Area() float64
}

type Circle struct {
	R float64
}

func (c *Circle) Area() float64 {
	return c.R * c.R * pi()
}

func NewCircle(r float64) *Circle {
	return &Circle{R: r}
}

func describe(s Shape) float64 {
	return s.Area()
}

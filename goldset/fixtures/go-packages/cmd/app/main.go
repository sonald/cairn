package main

import (
	"fmt"

	"example.com/shapes"
	"example.org/dep"
)

func main() {
	c := &shapes.Circle{R: 2}
	fmt.Println(c.Area(), shapes.NewCircle(1).Area())
	dep.NewCircle()
}

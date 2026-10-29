enum Flag { Some(u8), Off }
enum Shape { Circle(f64), Empty }
struct Circle;
impl Shape {
    fn empty() -> Self { Self::Empty }
}
fn f(s: Shape) -> Option<u8> {
    let _ = Flag::Off;
    match s { Shape::Circle(_) => {}, _ => {} }
    Some(1)
}

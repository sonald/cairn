struct A;
impl A {
    fn tick(&self) {}
}
struct B;
impl B {
    fn tick(&self) {}
}
fn probe(a: A) { a.tick(); }

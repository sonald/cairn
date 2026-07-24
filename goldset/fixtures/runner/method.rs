struct A;
impl A {
    fn tick(&self) {}
}
struct B;
impl B {
    fn tick(&self) {}
}
fn probe<T>(a: T) { a.tick(); }
fn typed(a: A) { a.tick(); }

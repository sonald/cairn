trait Close { fn close(&self); }
struct A;
impl Close for A { fn close(&self) {} }
struct B;
impl Close for B { fn close(&self) {} }
fn f(x: A) { x.close(); }

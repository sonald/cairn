trait Duplicate { fn act(&self); }
struct A;
impl Duplicate for A { fn act(&self) {} }

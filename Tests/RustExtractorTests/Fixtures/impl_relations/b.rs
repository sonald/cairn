trait Duplicate { fn act(&self); }
struct B;
impl Duplicate for B { fn act(&self) {} }

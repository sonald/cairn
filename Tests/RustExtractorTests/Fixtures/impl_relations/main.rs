trait Render { fn render(&self); }
struct Simple;
impl Render for Simple { fn render(&self) {} }
struct Boxed<T>(T);
impl<T> Render for Boxed<T> { fn render(&self) {} }
struct Inherent;
impl Inherent { fn render(&self) {} }
struct Shown;
mod fmt { pub trait Display { fn fmt(&self); } }
impl fmt::Display for Shown { fn fmt(&self) {} }

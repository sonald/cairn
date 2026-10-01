pub struct S { pub n: u32 }
pub struct Inner { pub x: u32 }
pub struct Outer { pub inner: Inner }
pub type Handle = Inner;
pub trait Read { fn f(&self) -> u32; }

impl S {
    fn get(&self) -> u32 {
        self.n
    }
}

pub fn use_it<T: Read>(ps: &S, r: T) -> u32 {
    let local: std::boxed::Box<S> = std::boxed::Box::new(S { n: 1 });
    let h: Handle = Inner { x: 1 };
    ps.n + r.f() + local.n + h.x
}

pub fn use_outer(o: &Outer) -> u32 {
    o.inner.x
}

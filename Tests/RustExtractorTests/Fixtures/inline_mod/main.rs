mod a { pub mod b { pub fn c() {} } }
fn main() { a::b::c(); }

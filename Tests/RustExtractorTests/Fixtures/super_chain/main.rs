mod outer {
fn helper() {}
mod inner {
use super::helper;
pub fn run() { helper(); }
}
}
fn main() { outer::inner::run(); }

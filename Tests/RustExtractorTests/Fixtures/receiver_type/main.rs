mod a;
use a::T;

fn annotated(receiver: T) {
    receiver.foo();
}

fn inferred() {
    let receiver = T::new();
    receiver.foo();
}

trait Erased { fn erase(&self); }
fn dynamic(receiver: &dyn Erased) {
    receiver.erase();
}

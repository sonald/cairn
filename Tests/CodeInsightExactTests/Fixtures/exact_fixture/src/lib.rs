pub fn answer() -> i32 { 42 }

pub fn relation_root() -> i32 { answer() }

pub trait Backend {
    fn get_completion(&self) -> String;
}

pub fn len() -> usize { 0 }

pub fn dependency_call(values: &[i32]) -> usize { values.len() }

pub struct TypedReceiver;

impl TypedReceiver {
    pub fn typed_edge(&self) {}
}

pub fn typed_receiver_call(receiver: TypedReceiver) { receiver.typed_edge() }

pub struct InferredReceiver;

impl InferredReceiver {
    pub fn new() -> Self { Self }
    pub fn inferred_edge(&self) {}
}

pub fn inferred_receiver_call() {
    let receiver = InferredReceiver::new();
    receiver.inferred_edge();
}

pub trait TraitObjectReceiver {
    fn trait_object_edge(&self);
}

pub fn trait_object_receiver_call(receiver: &dyn TraitObjectReceiver) {
    receiver.trait_object_edge();
}

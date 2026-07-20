mod duplicate;
mod models;

struct Holder {
    entry: BubbleCacheEntry,
    nested: Vec<UniqueGeneric>,
    ambiguous: Option<SharedEntry>,
}

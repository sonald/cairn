pub fn answer() -> i32 { 42 }

pub fn relation_root() -> i32 { answer() }

pub trait Backend {
    fn get_completion(&self) -> String;
}

pub fn answer() -> i32 { 42 }

pub fn relation_root() -> i32 { answer() }

pub trait Backend {
    fn get_completion(&self) -> String;
}

pub fn len() -> usize { 0 }

pub fn dependency_call(values: &[i32]) -> usize { values.len() }

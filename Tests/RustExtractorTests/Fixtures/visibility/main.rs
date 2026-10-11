pub struct Log {
    pub entries: Vec<u8>,
    pub(crate) cursor: usize,
    secret: u8,
}

impl Log {
    pub fn append(&mut self) {}
    pub(super) fn trim(&mut self) {}
    fn scan(&self) {}
}

pub trait Engine {
    fn get(&self) -> u8;
    fn flush(&self) {}
}

impl Engine for Log {
    fn get(&self) -> u8 { 0 }
}

pub(in crate::raft) const LIMIT: usize = 8;
pub(self) static COUNT: u8 = 0;
type Alias = Log;

mod tests {
    pub fn helper() {}
}

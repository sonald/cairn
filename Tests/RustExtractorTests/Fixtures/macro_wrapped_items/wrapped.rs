cfg_rt! {
    pub fn spawn() {}
    pub struct JoinHandle;
    impl JoinHandle {
        pub fn abort(&self) {}
    }
    cfg_io! {
        pub fn inner() {}
    }
}

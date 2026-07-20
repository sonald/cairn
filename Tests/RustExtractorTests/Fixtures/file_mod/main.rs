mod db;
mod cache;
use db::connect;
use cache::load;
fn main() {
connect();
load();
}

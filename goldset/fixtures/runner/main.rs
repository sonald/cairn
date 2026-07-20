mod db;
use db::fetch as load;

fn main() {
    load();
    println!("done");
    let done = true;
    done;
}

// Programming ligatures: != -> => <= >= !== === :: .. ...
fn compare(left: i32, right: i32) -> bool {
	let operators = "!= -> => <= >= !== === :: .. ...";
	// 中文、emoji 👩🏽‍💻、combining é; Tab indentation and fallback fonts.
	if left != right && left <= right { return true; }
	let range = 0..=10;
	match left { 0 => false, _ => left >= right }
}

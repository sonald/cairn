mod wrap_f4_combined {
	fn tab_indented() {
		let a = 1;
		let b = 2;
	}
    fn deep_indent() {
        let deeply_indented_line = "this line starts with more than twenty-four columns of leading spaces so the hanging indent clamp engages";
        let wrapped_follow_on = 1;
    }
    fn unicode() {
        // 中文注释：软换行必须保留字符位置的 UTF-8／UTF-16 对应。
        let emoji = "🚀🚀🚀 rocket fleet with family 👨‍👩‍👧‍👦 emoji and combining é accents";
        let cjk = "中文长行没有空格因此只能按字符断行中文长行没有空格因此只能按字符断行";
    }
    fn crlf_section() {
        let crlf_line = "this function uses CRLF line endings";
        let another_crlf_line = 42;
    }
    fn comments() {
        // A long comment line that wraps across visual rows and exercises the proportional comment font path when enabled.
        /* block comment */ let value = 1;
    }
}

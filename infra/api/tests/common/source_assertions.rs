#![allow(dead_code)]

pub fn function_signature_line<'a>(source: &'a str, function_name: &str) -> Option<&'a str> {
    source.lines().find(|line| {
        line.contains("fn ")
            && line.contains(function_name)
            && line.contains('(')
            && !line.trim_start().starts_with("//")
    })
}

pub fn function_body<'a>(source: &'a str, function_name: &str) -> Option<&'a str> {
    let fn_token = format!("fn {function_name}(");
    let start = source.find(&fn_token)?;
    let body_start = source[start..].find('{')? + start;
    let mut depth = 0usize;

    for (offset, ch) in source[body_start..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    let body_end = body_start + offset + 1;
                    return Some(&source[body_start..body_end]);
                }
            }
            _ => {}
        }
    }

    None
}
